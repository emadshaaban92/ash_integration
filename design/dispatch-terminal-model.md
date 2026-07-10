# Dispatch Terminal Model — age, not attempts (Design Doc)

**Status:** Accepted (implemented) · **Scope:** the *dispatch* layer's give-up
policy — how an undispatched `Event` becomes terminal (poison), what counts against
it, and where that logic lives. Pre-1.0; no backward-compatibility constraints, so
this replaces the attempt-ceiling model outright rather than layering on it.

> Internal maintainers' doc. Assumes familiarity with the outbound model
> ([`outbound-architecture.md`](outbound-architecture.md)) and the sibling
> [`delivery-retry-model.md`](delivery-retry-model.md), whose terminal model this
> mirrors one layer up. It defines the *target* model; the "As today" boxes
> describe what we're replacing.

---

## 1. Summary

The dispatch relay claims undispatched `Event`s (`FOR UPDATE SKIP LOCKED` + a 60s
soft lease), bumps `Event.dispatch_attempts` on the claim, fans each event out into
`EventDelivery` rows inside one batch transaction, and stamps `dispatched_at`. Until
now, an event that accrued `dispatch_attempts >= max_attempts` (default 20) became
**terminal (poison)**: `claim/1` refused it forever, its lane stayed blocked, and an
operator had to `:reset_dispatch` it by hand.

That ceiling counts the wrong thing. This design applies the delivery layer's
already-ratified terminal model (`delivery-retry-model.md` §6, §13, §14) to dispatch:

1. **`dispatch_attempts` becomes an honest, monotonic counter that never gates.**
   It is bumped on the claim (crash-safe — see §14 of the delivery doc), never
   forced, never reset. It is observability, not a verdict.
2. **Terminal-ness lives in its own field, `dispatch_terminal_reason`.** `nil` = not
   terminal; the one reason is `:expired`. `claim/1` refuses an event **iff**
   `dispatch_terminal_reason IS NOT NULL`.
3. **The only give-up policy is an opt-in age sweep.** `max_dispatch_age_ms` (default
   `nil` = never) takes an undispatched event older than the configured age terminal
   (`:expired`). With the default, **infra flakiness can never poison the backlog** —
   the whole failure class this change was written for.

## 2. What's wrong today (the motivation)

> **As today.** `dispatch_attempts` is both a claim counter *and* the terminal
> verdict: an event is poison the instant `dispatch_attempts >= max_attempts`.
> `:reset_dispatch` zeroes the counter to un-poison.

The ceiling counts **infra flakiness, not event-specific poison**, and here that
gap is total:

- `dispatch_attempts` is bumped on the **claim**, so *any* failure after the claim
  spends budget — including purely infrastructural ones. A `subscriptions_for` read
  raising in `prepare_messages` fails the whole prep chunk; a DB error in the batch
  transaction fails the batch. Both are infra.
- **Business failures never reach the failed path.** A `project`/transform failure is
  turned into a `:parked`/`:cancelled` *spec* — data — that commits as a parked row
  and stamps `dispatched_at`. It leaves the outbox; it does not re-spend budget.

So almost everything that can burn the ceiling is infra. With `max_attempts: 20` and
a 60s lease, ~20 minutes of degraded-DB operation poisons the *entire* outbox
backlog, each event then requiring a manual `:reset_dispatch`. The ceiling mostly
measures how flaky the database was, not whether any given event is genuinely stuck.

This is the exact failure mode the delivery redesign eliminated for its own layer
("a slow-but-fine target falsely poisoned by lease expiry" → §6 "false-poisoning is
designed out"). Dispatch kept the ceiling the project had already rejected — and is
worse-positioned to justify one, since its business failures are diverted to parked
data.

## 3. Principle: attempts count, age condemns

| Fact | Field | `nil` / zero means | Never encodes |
|------|-------|--------------------|---------------|
| *How many* claims | `dispatch_attempts :: integer` (default 0) | never claimed | terminal-ness, gating |
| *Is it terminal* | `dispatch_terminal_reason :: atom?` (`[:expired]`) | not terminal | how many attempts |

`dispatch_attempts` is the exact analogue of `EventDelivery.attempts`: bumped on the
claim, monotonic, honest, non-gating. `dispatch_terminal_reason` is the analogue of
`EventDelivery.terminal_reason`, narrowed to a single reason (§5).

## 4. Why unbounded re-emit is safe here (the asymmetry with delivery)

Delivery can drop its attempt ceiling because a retryable delivery is *paced by
backoff and throttled by suspension + probe*. **Dispatch has neither** — no backoff,
no suspension. A ceiling-less dispatch that keeps hitting a genuinely stuck event
re-emits it every ~60s (one lease window) forever. That sounds alarming; it isn't:

- The stuck event **holds its `(connection, event_key)` lane** — the scheduler
  high-water gate blocks the lane on the undispatched head regardless — so it is
  **one event per lane**, not a storm.
- `FOR UPDATE SKIP LOCKED` + the partial outbox-claim index make re-claiming one old
  row cheap, and every failed attempt records a `dispatch_error` and (once an age
  policy is set and crossed) fires `:expired` telemetry. It re-emits *loudly*, not
  silently.

So the liveness cost of unbounded re-emit is low — far lower than the current cost
(mass false-poison → per-event manual reset under any DB wobble). This is the same
"let it keep surfacing loudly" posture as delivery-retry-model §14.

## 5. Why `:expired` is the only terminal reason

Delivery has two terminal reasons (`:permanent`, `:expired`). Dispatch has one, on
purpose:

- **No `:permanent`.** A non-retryable *response* is a delivery-layer concept
  (there's no target to reject an event at dispatch). The only per-event dispatch
  failure that is deterministic — a spec the DB rejects on every materialization —
  is treated as a **bug to fix, not a steady state to engineer around**
  (delivery-retry-model §14, "let it crash"). It re-emits loudly and is either fixed
  or keeps surfacing; we do not build a classifier to make it terminal.
- **`:expired` only**, set by the opt-in age sweep. `nil` (never expire) is the safe
  default: a persistently-failing dispatch retries forever, bounded operationally by
  the lane block and (if configured) the age sweep.

## 6. The sweep and its home

`Dispatcher.sweep_expired/0` takes every undispatched, non-terminal event older than
`max_dispatch_age_ms` terminal in one bulk `:expire_dispatch` update (idempotent —
`dispatch_terminal_reason IS NULL` is its precondition, so it is multi-node safe),
logs, and emits `[:ash_integration, :dispatch, :expired]`. It is a no-op unless an
age is configured.

**The `Retention` GenServer drives it** on its existing periodic tick, exactly as the
delivery age sweep piggybacks on the `Health` GenServer rather than spawning a
dedicated process (delivery-retry-model §13, `health.ex`). Retention already owns
the Event table's age policy (it reasons carefully about *not* reaping a stuck event
and unblocking its lane), so "mark terminal when too old to dispatch" sits naturally
beside "delete when past the retention window." Configuration ownership stays with
the dispatch stage: `max_dispatch_age_ms` lives in `Dispatch.Supervisor`'s schema and
is read cross-tree — the same split delivery uses (`Health` reads
`Delivery.Supervisor.max_delivery_age_ms/0`).

## 7. Operator recourse

- **`:reset_dispatch`** (unchanged entry point, changed body) clears
  `dispatch_terminal_reason`, `claimed_at`, and `dispatch_error`. It **no longer
  zeroes `dispatch_attempts`** — the counter stays honest across resets (an event
  attempted 47 times reads 47, not 0). The relay re-claims on its next poll. As
  before, it leaves `dispatched_at` alone, so resetting an already-dispatched event
  is a harmless no-op.
- **`Dispatcher.reset_terminal/0`** — the bulk affordance: one `:reset_dispatch`
  bulk-update over every terminal event, so an operator recovering from an incident
  clears the backlog in one call instead of N. Returns the count reset.

> An `:expired` event whose `terminal_reason` is cleared but whose age still exceeds
> `max_dispatch_age_ms` will be re-expired on the next sweep — identical to delivery's
> `:expired` semantics. Raising (or clearing) the age policy is the durable recovery;
> the reset affordances are for the common case where the operator has fixed the
> cause and the events are within the window (or the policy is `nil`).

## 8. What this removes vs today

- The `dispatch_attempts >= max_attempts` **claim gate** and the `max_attempts`
  config knob (replaced by `dispatch_terminal_reason IS NULL` + `max_dispatch_age_ms`).
- The poison side-effects on the **failed path** — `record_dispatch_errors/1` no
  longer classifies terminal, logs "poison," or emits `[:ash_integration, :dispatch,
  :poison]`. It records the raw `dispatch_error` (visibility) and nothing else; the
  terminal signal (`:expired` telemetry + log) now comes from the sweep, exactly once.
- The `dispatch_attempts` **reset** on `:reset_dispatch` — the counter is now
  monotonic.

## 9. Alternatives considered

- **Keep the attempt ceiling, just raise it.** Doesn't change *what* is counted;
  a longer DB wobble still poisons the backlog. Rejected — the unit is wrong, not
  the magnitude.
- **Only count attempts that reached `handle_batch`** (exclude prep-read failures).
  A real mitigation — a `subscriptions_for` raise otherwise fails a whole prep chunk
  across unrelated `(type, version)` groups — but `handle_batch` DB failures are also
  infra, so it doesn't separate infra from event-poison; it narrows the blast radius
  without fixing the unit. Rejected in favor of dropping the count entirely.
- **Derive expiry at claim time (no stored terminal bit).** Cheaper (no column, no
  sweep) but breaks operator recourse — age only grows, so `:reset_dispatch` can't
  un-stick — and loses the fire-once telemetry. Rejected; the stored bit is what
  makes reset and the signal work (same reasoning as delivery's `terminal_reason`).
- **A dedicated dispatch-expiry GenServer.** Cleaner ownership but a new process for
  a once-a-minute idempotent bulk update, when `Retention` already sweeps this exact
  table. Rejected in favor of piggybacking, mirroring delivery/Health.
