# Delivery Retry, Backoff & Terminal Model (Design Doc)

**Status:** Proposed · **Scope:** the per-`EventDelivery` lifecycle — retry
timing, backoff, terminal (give-up) semantics, and where that logic lives.
Pre-1.0; no backward-compatibility constraints, so this replaces the current
model outright rather than layering on it.

> Internal maintainers' doc. Assumes familiarity with the outbound model
> ([`outbound-architecture.md`](outbound-architecture.md)) and derived suspension
> ([`connection-health.md`](connection-health.md)). It defines the *target* model;
> the "As today" boxes describe what we're replacing.

---

## 1. Summary

Every `EventDelivery` is a small state machine: try to send, and on failure decide
*retry later*, *rate-limit until a specific time*, or *give up*. Today that decision
is smeared across two overloaded fields and split between the relay and the
scheduler, which has produced real bugs (a non-retryable `HTTP 400` retrying every
~30s forever; a healthy endpoint falsely suspended by one bad payload; a slow-but-
fine target falsely poisoned by lease expiry).

This design rests on one rule — **one field, one fact** — and one structural move:

1. **Three orthogonal facts, three fields.** *When* it may run next
   (`next_attempt_at`), *how many* attempts it has had (`attempts`), and *whether it is
   terminal* (`terminal_reason`). No field is ever forced to a sentinel to stand in
   for another.
2. **A new `:failed` state, and the lane's uniqueness index widened to
   `state IN ('scheduled', 'failed')`.** A waiting-to-retry or terminally-stuck row
   sits in `:failed`, still holding its lane via the index — so **per-key ordering
   stays a hard database invariant**, not something a query has to get right.
3. **The relay becomes dumb; the scheduler owns all scheduling.** The relay only
   *executes* a `:scheduled` row and reports the outcome (`:delivered` or
   `:failed` + classification). The scheduler owns *what runs next and when* —
   lane-head selection, backoff eligibility, terminal classification, suspension,
   high-water — in one place.

The result: `:scheduled` means exactly "a worker is executing this right now,"
`attempts` is an honest count that is never forced or reset, terminal is an
explicit bit, and ordering never depends on query correctness.

## 2. What's wrong today (the motivation)

> **As today.** A failed-but-retrying row *stays* `:scheduled`; a permanently-dead
> row (poison) *also* stays `:scheduled`; `attempts` is bumped past a ceiling to
> *mean* "terminal." Terminal-ness is inferred from `attempts >= max_attempts`, and
> the failure→retry/terminal decision is written by the **relay**, in place, on the
> scheduled row.

Two overloads, both the same anti-pattern one level apart:

- **`:scheduled` means three operationally different things** — executing now,
  waiting out a backoff, and dead-forever. The claim query, `pick_suspended`, and
  `ParkOnSuspend` each special-case the difference.
- **`attempts` means two things** — a retry counter *and* a terminal verdict (a
  permanent failure is forced to `max_attempts` so the claim gate skips it). A row
  attempted once then reports `attempts = max` in telemetry and the dashboard.

Consequences we've actually hit:

- A non-retryable `4xx` marched the full backoff ladder, filled the subscription
  health window, tripped auto-suspension, and then looped on the recovery probe
  forever — never terminal because each probe cycle cleared its attempts.
- A single bad payload on a *healthy* endpoint could suspend the whole subscription.
- A slow-but-fine target whose lease expires mid-send accrues claim-count toward the
  ceiling and can be **falsely poisoned**.

## 3. Principle: one field, one fact

| Fact | Field | `nil` / zero means | Never encodes |
|------|-------|--------------------|---------------|
| *When* may it run next | `next_attempt_at :: utc_datetime_usec?` | no wait — eligible as soon as the lane frees | terminal-ness |
| *How many* attempts | `attempts :: integer` (default 0) | never attempted | terminal-ness, gating |
| *Is it terminal* | `terminal_reason :: atom?` | not terminal | timing |

The fresh state is `(attempts=0, next_attempt_at=nil, terminal_reason=nil)` — obvious:
deliver as soon as this is the lane head. Every transition below moves exactly these
fields plus `state`.

Rejected alternative — *"non-retryable ⇒ `next_attempt_at = nil`"*: `nil` already means
"eligible now," so a terminal row set to `nil` is re-claimed on the next poll. That
is the original forever-loop. Terminal is its own bit; timing never carries it.

## 4. The state machine

```
                 ┌──────────── promote ───────────┐
                 │  (scheduler: lane-min & eligible)│
                 ▼                                  │
   (fresh)   pending ──────────────────────────▶ scheduled ───── deliver ─────▶ delivered
                 ▲                                  │   ▲                      (lane frees;
   backlog:      │                                fail   │                       next head
   many per lane │                                  ▼   │  re-promote            promotes)
   (NOT indexed) │                               failed ─┘  (when eligible)
                 │                                  │
                 │                                  └── + terminal_reason ⇒ held forever
                 │                                         (lane blocked, operator-only)
   cancel / operator-skip ◀──────────────────────── (any) ──▶ cancelled  (leaves the lane)
```

| State | Meaning | In the lane index? | Whose court |
|-------|---------|--------------------|-------------|
| `:pending` | fresh backlog, never attempted | **no** (many per lane) | scheduler |
| `:scheduled` | **in flight right now** (promoted; claimed or about to be) | yes | relay |
| `:failed` | had ≥1 attempt; the lane's held head, awaiting the scheduler's verdict (retry vs terminal) | yes | scheduler |
| `:delivered` | success; leaves the lane | no | — |
| `:cancelled` | operator/lifecycle skip; leaves the lane | no | — |

`:parked` and `:suppressed` are **out of scope** here — see §11.

The key shift from today: **retrying and terminal rows leave `:scheduled` for
`:failed`.** `:scheduled` becomes single-meaning. `:failed` is a *pool with
attributes* (retrying vs terminal, disambiguated by `next_attempt_at`/`terminal_reason`)
— not a sentinel overload, because the distinguishing facts live in their own fields.

## 5. The lane invariant (the crown jewel)

Per-key ordering is: for a lane `(connection_id, event_key)`, deliver events in
`event_id` order, and never deliver a later event before an earlier one is delivered
or terminally resolved.

We keep this a **hard DB invariant** by widening the existing partial unique index:

```
UNIQUE (connection_id, event_key) WHERE state IN ('scheduled', 'failed')
```

> **As today** it is `WHERE state = 'scheduled'`.

This enforces **at most one *active head* per lane**, where "active" = in-flight
(`:scheduled`) *or* held-waiting (`:failed`). Therefore:

- **Backoff ordering** — while `e1` is `:failed` (backing off), any attempt to
  promote `e2` (`:pending → :scheduled`) is a second active member for the lane and
  is **rejected by the index**. Automatic.
- **Terminal ordering** — `e1` `:failed` + `terminal_reason` holds the slot forever;
  `e2` is blocked forever. Same index, no special case.
- **A scheduler bug cannot violate ordering.** Even if the promotion query
  mis-selected, the write to `:scheduled` fails against the index. Correctness of
  ordering lives in the database, not in query logic.

Re-promotion of a failed head (`:failed → :scheduled`) is an **update of the same
row** — still one lane member — so the index is satisfied throughout. A lane frees
only when its head reaches `:delivered` or `:cancelled`.

> **Formal statement (the one thing to test to death, §17).** For each lane, let
> `H` = the `{:pending, :failed}` row with the smallest `event_id`. The scheduler
> promotes a row to `:scheduled` **only if it is `H` and `H` is eligible**. If `H`
> is not eligible (backing off, terminal, or its entity suspended), the scheduler
> promotes **nothing** for that lane. The index is the backstop; the query is the
> optimization.

## 6. The fields

- **`attempts :: integer`, default 0.** Monotonic count of *claims* (bumped on the
  claim, so a crash mid-send still counts — §14). Never forced, never reset. Doubles
  as the backoff exponent: because a row's *success ends it*, a single row's
  `attempts` is exactly its own consecutive-failure streak, so
  `backoff(attempts)` is correct without a separate streak counter. **No ceiling** —
  `attempts` never gates claiming.
- **`next_attempt_at :: utc_datetime_usec?`.** Earliest time the row may become the
  active head again. `nil` = no wait. Purely timing. (Today's field, **kept as-is —
  no rename**; it gains the per-response policy of §12 and its gate moves from
  claim-time to promotion-time.)
- **`terminal_reason :: atom?`, one_of `[:permanent, :expired]`.** The single
  terminal bit. `nil` = not terminal. Set ⇒ never promote; lane held; operator-only
  recovery.

Unchanged: `state`, `claimed_at` (soft lease + fence token), `last_error`,
`delivery_metadata`.

Terminal ⟺ `terminal_reason IS NOT NULL`, **everywhere** — claim, promotion,
`pick_suspended`. No site ever consults `attempts` to decide terminal-ness again.

### Bonus: false-poisoning is designed out

With no attempt ceiling, a lease that expires mid-send (bumping `attempts`) only
nudges the backoff exponent — it can never make a row terminal. The entire
"falsely poisoned slow target" failure mode disappears.

## 7. Division of labor

| | Relay (muscle) | Scheduler (brain) |
|--|----------------|-------------------|
| Owns | *executing* a `:scheduled` row and reporting the outcome | *what runs next and when* |
| On success | `:scheduled → :delivered` | — |
| On failure | `:scheduled → :failed`, record classification (`last_error`, `delivery_metadata`), write the health `Log`, release lease | — |
| Never does | retry timing decisions, lane selection, suspension, terminal *gating* | execute a send |
| Reads | the transport result in hand | the recorded facts on `:pending`/`:failed` rows |

`attempts` is bumped on the **claim** (in `Dispatcher.claim`), not on failure — so
the count is crash-safe and "one bump per attempt" holds even when the worker dies.

### Sub-decision A — where the derived timing/verdict is *computed*

The scheduler owns the *decisions*; the open question is who computes the *pure
functions* (`backoff(attempts)`, "is this classification terminal").

- **(A1, recommended)** The **relay stamps** the derived values as pure functions of
  the result it already holds, on the `:scheduled → :failed` transition:
  - non-retryable `:response` ⇒ `terminal_reason = :permanent`;
  - otherwise ⇒ `next_attempt_at = now + clamp(backoff(attempts) | Retry-After)`.

  The scheduler then only *promotes* eligible failed heads. `next_attempt_at` keeps one
  uniform meaning ("earliest eligible; `nil` = ASAP"). The relay's "policy" is two
  stateless functions on the metadata in hand — no DB round-trip, no ambiguity.
- **(A2)** The relay records only raw classification + `last_failed_at`; the
  **scheduler** classifies terminal and computes eligibility on the fly each tick.
  Maximally dumb relay, but a heavier promotion query and `next_attempt_at = nil` on a
  `:failed` row becomes context-dependent ("unclassified" vs "ASAP").

A1 keeps the relay *decisions*-free while avoiding the ambiguity. **Ratified: A1.**

## 8. Failure taxonomy → outcome

The transport returns `{:error, %{failure_class, retryable, error_message, ...}}`.
Under A1 the relay maps it as:

| Trigger | `failure_class` / signal | `retryable` | Row outcome | Fields written |
|---|---|---|---|---|
| Success | — | — | `:delivered`, lane frees | `state=:delivered` |
| Server error (5xx) | `:response` | true | `:failed`, retry | `next_attempt_at = now + backoff` |
| Rate limited (429; 503+Retry-After) | `:response` | true | `:failed`, wait server's time | `next_attempt_at = now + clamp(server)` |
| Deterministic reject (400/401/403/404/409/422, 3xx) | `:response` | false | `:failed`, **terminal** | `terminal_reason = :permanent` |
| Reachability (timeout, refused, DNS, TLS) | `:transport` | true | `:failed`, retry; feeds connection window | `next_attempt_at = now + backoff` |
| Config/transport dead (removed transport, bad credential) | `:transport` | false | `:failed`, retry; feeds connection window → suspends | `next_attempt_at = now + backoff` |
| Suspended-entity probe, retryable | any (logged `:probe`) | — | `:failed`, awaits probe pacing | `next_attempt_at = now + backoff`; Log `:probe` |
| Suspended-entity probe, permanent | `:response` | false | `:failed`, **terminal** | `terminal_reason = :permanent` |
| No-result contract bug | synthesized, no keys | (default true) | `:failed`, retry | `next_attempt_at = now + backoff` |
| Aged out (opt-in, §13) | — | — | **terminal** | `terminal_reason = :expired` |

Two rules worth stating explicitly:

- **`retryable` only decides terminal-ness for `:response`.** A non-retryable
  `:transport` failure is *not* per-row terminal — it reflects endpoint/config
  health, so it feeds the **connection** window and is governed by
  suspension + probe, which is the right control for "this endpoint is unhappy."
- **`:response` retryable failures** (5xx/429/408) feed the **subscription** window.
  Correctly classifying `408`/`429` as retryable is what keeps a transient
  rate-limit out of the `:permanent` bucket (this transport fix is independently
  valuable and should land on its own — see §16).

Health-logging (`failure_class`, and `:probe` when the entity was suspended at
execution) stays in the relay: it is *observability* about what happened, which is
the relay's "report" job, and it is orthogonal to the retry/terminal decision.

## 9. The scheduler: promotion

Unified over both promotable states. In pseudocode (one pass, per lane discipline):

```
for each lane (connection_id, event_key) with NO active head (no :scheduled/:failed
                                                               that is in flight):
    H := the {:pending, :failed} row with the smallest event_id in the lane
    if H is null: continue
    if H.entity is suspended: continue            # probe handles suspended entities
    if H.state == :failed and H.terminal_reason is not null: continue   # blocked forever
    if H.state == :failed and H.next_attempt_at > now(): continue           # still backing off
    if over high-water for this connection: continue                    # backpressure
    promote H:  H.state -> :scheduled             # UPDATE; the index adjudicates races
```

Notes:

- **The index adjudicates races.** Two ticks promoting the same lane, or a fresh
  `:pending` racing a `:failed` re-promote, resolve to one winner via the
  `{scheduled, failed}` unique index; the loser's write no-ops. The query *selects*
  lane-min for correctness-of-order; the index *guarantees* no double-head.
- **A re-promote is `:failed → :scheduled`** on the same row — the head keeps its
  identity and `attempts`; nothing resets.
- **High-water counts in-flight work** (`:scheduled`), **not** `:failed`. A lane
  held by a backing-off or terminal `:failed` head must not consume a work slot.

## 10. The relay: claim + execute + report

- **Claim** (`Dispatcher.claim`) selects `state = 'scheduled'` and lease-free, bumps
  `attempts`, stamps `claimed_at`. It no longer checks `next_attempt_at` or any ceiling:
  a `:scheduled` row is, by construction, already due (the scheduler gated that at
  promotion). Claim shrinks to "lease the ready rows."
- **Execute** over the transport, then **report** exactly one of:
  - success ⇒ `:scheduled → :delivered` (fenced on `claimed_at`);
  - failure ⇒ `:scheduled → :failed` (fenced), recording classification, the health
    `Log`, and — under A1 — the derived `next_attempt_at` **or** `terminal_reason`;
    release the lease.
- **The lease-token fence is unchanged**: every result write filters on the
  `claimed_at` the claimer saw, so a stale claimer (lease expired, row re-claimed)
  no-ops instead of resurrecting a row.

The relay has **no** suspended-vs-healthy branch, **no** poison branch, **no**
backoff/terminal policy of its own beyond the two pure functions of A1.

## 11. Suspension, the probe, and the retirement of park

> See [`connection-health.md`](connection-health.md) for the derived-suspension
> model; this section only states what changes.

- **Suspension is unchanged in spirit** — derived from the health `Log` windows
  (transport → connection, response → subscription), orthogonal to per-row terminal.
- **`ParkOnSuspend` (the `:scheduled → :pending` drain on suspend) retires.** Its job
  was to stop the relay hammering a dead endpoint by draining the pile of
  `:scheduled` rows that accumulated during backoff. In this model those rows are
  already `:failed` (held-waiting), and the scheduler simply *stops promoting* a
  suspended entity. There is no `:scheduled` pile to drain.
  - *Residual (optional):* a row the scheduler promoted just before the suspend, not
    yet claimed, will take **one** delivery attempt before settling back to
    `:failed`. Bounded, no loop. If we want to reclaim even that, a tiny optional
    cleanup can revert **un-leased** `:scheduled` rows to `:failed` on suspend — an
    optimization, not load-bearing.
- **The probe barely changes.** It promotes one suspended entity's oldest `:failed`
  head to `:scheduled` to test recovery; `pick_suspended` skips entities with a live
  `:scheduled` (in-flight) row so a probe never stacks. A probe failure is logged
  `:probe` (out of the health windows) and lands back in `:failed`, awaiting the next
  probe.
- **`:parked` / `ParkedHealth` are unrelated and untouched.** `:parked` is a
  *build* failure (a broken transform/`project` — no payload to send), cleared by
  `reprocess`, and the opt-in parked-suspend is its own health dimension. Neither has
  anything to do with delivery-attempt retries.

## 12. Retry-After & clamping

For a rate-limit response (`429`, or `503` carrying `Retry-After`), the timing comes
from the target, parsed via `Req.Response.get_retry_after/1` (handles both
delta-seconds and HTTP-date). The target is usually the integrator's *own* endpoint,
so an outlandish value only parks *their* lane — but a clamp is cheap insurance:

```
next_attempt_at = now + clamp(server_value, min_retry_after, max_retry_after)
```

The same `max_retry_after`/backoff cap bounds the computed `backoff(attempts)`. Both
clamps are config (§15).

## 13. Terminal reasons & the give-up policy

| `terminal_reason` | Set by | When |
|---|---|---|
| `:permanent` | relay (A1) / scheduler (A2) | non-retryable `:response` — the target refuses this exact payload regardless of health |
| `:expired` | a periodic sweeper | **opt-in** age policy: `now - inserted_at > max_delivery_age` |

- **`max_delivery_age` defaults to `nil` (never expire) — safe by default.** With
  `nil`, a persistently-failing-but-*retryable* lane retries forever, paced by
  backoff and bounded operationally by suspension + probe; nothing is silently
  dropped. An operator who prefers "give up after N days" sets a value, and the
  sweeper marks stale rows `:expired` (idempotent: `WHERE terminal_reason IS NULL`,
  multi-node safe).
- **No crash/stall terminal** — see §14.

## 14. Crashes: let it crash

We deliberately do **not** build a crash/stall backstop (no `unresolved_claims`
counter, no `:stalled` reason). The policy:

- Transports and the delivery path **return classified errors**, never raise for
  expected failures. A function that can fail returns `{:error, classified}`.
- If something *unexpected* raises, it's a **bug to fix**, not a steady state to
  engineer around. We let it crash; the supervisor restarts; the row is re-claimed
  (its `attempts` bumped on the claim keeps the count honest) and either the bug is
  fixed or it keeps surfacing loudly.
- The optional `max_delivery_age` sweep (§13) is the only age bound, and only if an
  operator opts in.

This keeps the model minimal and honest — no field or sweeper exists to paper over
code that should have returned an error.

## 15. Configuration

| Knob | Purpose | Default |
|---|---|---|
| `backoff_base_ms`, `backoff_max_ms`, `backoff_jitter_ratio` | generic retryable pacing | (as today) |
| `min_retry_after_ms`, `max_retry_after_ms` | clamp for server-provided `Retry-After` (and the backoff cap) | 1s / 1h |
| `max_delivery_age` | opt-in `:expired` policy; **nullable** | `nil` (never) |
| ~~`max_attempts`~~ | **removed** — no attempt ceiling | — |

## 16. Decisions (ratified)

1. **Sub-decision A (§7): A1** — the relay stamps the derived
   `next_attempt_at`/`terminal_reason` as pure functions of the transport result.
2. **`:parked` reconciliation (§11): untouched** — `:parked` and the opt-in
   parked-suspend keep their own state/semantics; this design touches only
   `:pending`/`:scheduled`/`:failed`/`:delivered`/`:cancelled`.
3. **The `408`/`429` transport-classification fix ships as part of this change**
   (not a separate PR) — it's the first, standalone commit in the sequence.
4. **Ordering is inviolable** — block the lane on terminal; never auto-advance past
   a permanent head.
5. **`max_delivery_age` default `nil`** (never expire) — safe by default.
6. **No crash backstop** — let it crash (§14).

## 17. Ordering test matrix (the non-negotiable suite)

Ordering correctness is the thing we cannot get wrong, so it gets an exhaustive
matrix. Every row asserts *no later `event_id` is delivered before an earlier one is
`:delivered` or `:cancelled`*.

- **Backoff holds the lane:** `e1` fails (→ `:failed`, `next_attempt_at` future), `e2`
  `:pending` behind it → scheduler promotes nothing for the lane; `e2` never leaves
  `:pending`; when `e1`'s `next_attempt_at` elapses, `e1` (not `e2`) is re-promoted.
- **Index rejects the ordering violation directly:** force the scheduler to attempt
  promoting `e2` while `e1` is `:failed` → the write is rejected; state unchanged.
- **Terminal holds the lane forever:** `e1` `:permanent` → `e2..en` never promote;
  operator *skip* (`e1 → :cancelled`) frees the lane → `e2` promotes; operator
  *retry* (clear `terminal_reason`) → `e1` re-promotes ahead of `e2`.
- **Delivery advances the lane:** `e1` delivered → `e2` becomes head and promotes.
- **Concurrency:** two scheduler ticks; scheduler vs probe; fresh `:pending` racing a
  `:failed` re-promote — exactly one becomes `:scheduled`, and it is the lane-min.
- **Suspension:** suspended entity's failed heads stay `:failed`; only the probe
  promotes one; a probe failure logs `:probe` and does not perturb the window; no
  drain to `:pending` occurs.
- **Crash-safety:** a claim that never reports (simulated) leaves `attempts` bumped
  and the lease to re-claim; no terminal state is invented.

Plus the per-case unit tests: one per row of the §8 table (including the
`408`/`429`-retryable and `400`/`422`/`302`-permanent cases), and the
`next_attempt_at` clamp bounds.

## 18. What this removes vs today

- The poison **ceiling** as a terminal mechanism (`max_attempts` gate, `poison?/1`,
  `record_poison`, poison messaging) — replaced by `terminal_reason` + the optional
  `:expired` sweep.
- Forcing/inflating `attempts` to signal terminal (the `MarkTerminal`-style hack).
- The `attempts` reset on reschedule — `attempts` is now truly monotonic.
- `ParkOnSuspend`'s active `:scheduled → :pending` drain (§11).
- The relay's suspended-vs-healthy-vs-poison branching — the relay is dumb.
- `next_attempt_at` is **reused as-is (no rename)**; it gains the per-response policy
  of §12 (429 `Retry-After`, clamped) and its eligibility gate moves from claim-time
  to promotion-time.

## 19. Alternatives considered

- **Keep everything in `:scheduled` (status quo, with the field disentangling
  only).** Retains the `:scheduled` overload and leaves the relay owning
  retry/terminal in place. Rejected: doesn't achieve the brain/muscle split and
  keeps the hot state ambiguous.
- **Pure `:pending` model (no `:failed` state).** On failure, return the row to
  `:pending` and let the scheduler own everything. Conceptually clean, but it moves
  the "lane held during backoff" guarantee out of the index and into the promotion
  query — a new correctness burden on the one thing we won't compromise. The
  `:failed` state buys that guarantee back for the price of one state value and a
  widened index. Rejected in favor of §4.
- **`next_attempt_at = nil` as the terminal signal.** Collides with "eligible now" (§3).
  Rejected.
- **A crash/stall counter (`unresolved_claims` + `:stalled`).** Rejected in favor of
  "let it crash" (§14).
