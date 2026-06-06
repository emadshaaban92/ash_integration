# Content Suppression (Design Doc)

**Status:** As-built · **Scope:** suppressing redundant outbound deliveries —
content-addressed dedup, field-level subscription, and the relationship to
in-transaction event redundancy. Pre-1.0; no backward-compatibility constraints.

> Internal maintainers' doc. It assumes the [outbound
> architecture](outbound-architecture.md) — `Event` vs `EventDelivery`, the
> `(connection, event_key)` lane, coalescing on `(subscription, event_key)`, and
> the dispatch/delivery relays. This is the *why*; the guides are the *how*.

---

## 1. Summary

Three related complaints motivate this:

1. **Redundant `Event`s in one transaction.** Capture fires per Ash action, and
   actions call each other, so nothing stops the *same* logical change from being
   captured several times inside one transaction (e.g. a `confirm` that internally
   `update`s, both declared for the same event type).
2. **No field-level subscription.** A subscriber can't say *"only tell me when
   *these* fields change."* They can shape the payload (`project` + Lua), but a
   change to an unrelated field still produces a delivery.
3. **No content dedup.** We resolve a per-subscription payload but never ask
   *"is this byte-for-byte what we last sent this subscriber?"* — so a stock value
   that didn't actually change still ships when some other field on the record did.

The key realization: **#2 and #3 are the same feature**, and once it exists, **#1
stops mattering on the wire**. This doc specifies that one feature —
**content-addressed delivery suppression**, scoped to `(subscription, event_key)`
and compared against the **last delivered body only** — and explains why we do
*not* try to fix #1 at capture.

The feature is **opt-in per subscription** (`suppress_unchanged?`, default
`false`), so it changes nothing for existing subscriptions until enabled.

## 2. The core idea

> **Suppress a delivery whose projected body equals the body we last delivered to
> this subscriber on this `event_key`.**

Two properties make this fall cleanly out of the existing model:

- **Scope = `(subscription, event_key)`.** The same scope coalescing already uses
  (`dispatch_event.ex`), and the same scope the snapshot invariant names: the event
  key is *"what the payload is a complete snapshot of."* Two snapshots of the same
  thing for the same subscriber are exactly what we can compare for equality.
- **The body is per-subscription.** `project/3` redaction and the Lua transform run
  per subscription, so the body a subscriber receives already reflects *their*
  projection. **Field-level subscription is therefore emergent:** if a subscriber's
  projection narrows the body to `{product_id, stock}`, then a change to any other
  field yields an identical body → identical hash → suppressed. We do **not** build
  a "watched fields" DSL; field selection *is* the projection the author already
  writes, and content-equality of that projection is the trigger.

### 2.1 Why "last delivered", not "ever delivered"

State recurs. `stock: 5 → 6 → 5` must deliver the final `5` even though we sent a
`5` before. So the comparison is against **only the immediately-previous delivered
body** on the lane, never a set of all historical bodies. This is precisely Kafka
log-compaction / HTTP `ETag` / conditional-`GET` semantics: **suppress a
consecutive duplicate state, always deliver a transition.** It composes with the
snapshot invariant the system already depends on.

### 2.2 Why this is safe to evaluate at schedule time

A lane (`(connection, event_key)`) has **at most one in-flight `:scheduled` row**
(the partial unique index), and the scheduler promotes a lane's next head **only
when the lane's in-flight slot is free** — i.e. the previous head is already
terminal (`delivered`/`suppressed`/`cancelled`). So at the moment the scheduler
considers a head, *the outcome of the one before it on that lane is already known*,
and **"the last delivered body" is unambiguous and current**. That makes the
scheduler the natural place to decide suppression (§5), matching the "last
*delivered* thing" requirement exactly — and a suppressed head never even becomes a
delivery. (Evaluating at dispatch/materialize would instead compare against a
possibly-stale baseline, since a newer sibling can materialize before an older one
is delivered — so it must be post-schedule, not at dispatch.)

## 3. What gets hashed

**The body only**, by default:

- HTTP → the resolved `delivery["body"]` term.
- Kafka → the resolved `delivery["value"]` term.

Headers are **deliberately excluded**. The default header set carries
`x-event-id` / `event-id` — unique per event — so hashing headers would defeat
suppression on essentially every delivery. (The signature and auth headers aren't
in the snapshot at all; they're injected live — see the architecture doc §11.) The
hash is taken over the body the transform produced, after `project` + Lua, so it is
already the per-subscriber projected payload.

### 3.1 The `dedup_on` escape hatch (headers / custom identity)

A minority of authors put meaningful state in a header (they control headers now),
or want to *exclude* a noisy body field from the comparison. Rather than a config
matrix ("hash body / body+headers / everything" — where only "body" is ever a safe
default), we give the transform one precise lever, in the language they already
author:

```lua
-- default: we hash defaults.body / defaults.value
-- override: name the exact identity to compare on, on the returned table
function transform(event, defaults)
  defaults.dedup_on = { tenant = defaults.headers["x-tenant"], stock = defaults.body.stock }
  return defaults
end
```

If the returned table carries a `dedup_on` key, it is hashed **instead of** the
body. This is strictly more powerful than a header toggle — the author can
*include* a specific header without dragging in `x-event-id`, *exclude* a noisy
body field, or collapse "body + one header" into one canonical identity — and the
`event-id` footgun becomes structurally impossible because the author names fields
*in* rather than filtering bad ones *out*. `dedup_on` is **not** a wire field: the
Resolver pops it from the returned table before building the descriptor, so it
never reaches the transport.

### 3.2 Canonicalization

The hash MUST be over a **canonical serialization** (recursively sorted map keys)
of the chosen term, so that two equal maps that happen to encode in different key
orders don't read as a spurious change (which would cost an extra delivery — safe,
but defeats the point). Concretely: a canonical-JSON encode (sorted keys) → SHA-256,
stored as a short hex/binary string. The encoder must be deterministic for the term
types `produce`/transform can yield (maps, lists, strings, numbers, booleans, nil).

## 4. Data model changes

On **`EventDelivery`** (via its transformer):

- `body_hash :: string, nilable` — the canonical hash of the dedup target, computed
  at **materialize** (in `Specs`, where the resolved descriptor is in hand) and
  stored on the row. Nil for parked/cancelled rows (no deliverable body) and for
  rows of non-`suppress_unchanged?` subscriptions (we simply don't compute it).
- A new terminal **`:suppressed`** state (the sixth) — a delivery that was resolved
  and found content-identical to the last *delivered* body, so **no bytes were
  sent**. It is terminal and leaves the lane exactly like `delivered`/`cancelled`,
  but is a **distinct, queryable bucket** so it never pollutes the operational
  meaning of `delivered`.

**`delivered` is reserved for real sends.** This is the load-bearing rule: an
operator monitoring a target trusts "last `delivered`" to answer *"when did bytes
last actually go out?"* — so a withheld delivery must **not** read as `delivered`,
or a quiet-but-suppressing lane would show false-green while a real problem (events
not flowing, endpoint silently broken for other events) hides behind it.

**The baseline is the last `delivered` row only — and that is sufficient.** We only
ever suppress when the new body *equals* the last delivered body, so the last real
`delivered` row already carries that body; suppressed rows are equal to it by
construction and never need to be the baseline themselves. Walk `5 → 6 → 5`: deliver
`5` (baseline `5`) → `5` again equals baseline → suppress (baseline still `5`) → `6`
differs → deliver (baseline `6`) → `5` differs from `6` → deliver. The baseline that
makes dedup correct is therefore *the same row* as the honest operational
"last delivered" — the two needs stop competing. We reuse the existing
`(subscription_id, event_key, state)` index for the lookup (most recent `delivered`
row for the lane). **No new table.**

On **`Subscription`** (via its transformer):

- `suppress_unchanged? :: boolean, default false, always_select?: true` — the
  opt-in. Orthogonal to `notify_on_every_change`.

### 4.1 Interaction with the two existing delivery modes

`suppress_unchanged?` is orthogonal to coalescing, so it composes into a useful
matrix:

| `notify_on_every_change` | `suppress_unchanged?` | Behavior |
|---|---|---|
| `false` (default) | `false` (default) | **Today's default** — coalesce pending siblings to latest per key. |
| `false` | `true` | Coalesce to latest, **and** drop the latest if it equals what we last delivered. |
| `true` | `false` | **Today's** every-change firehose. |
| `true` | `true` | **Every *distinct* state** — no coalescing of pile-ups, but identical consecutive states are suppressed. (Not expressible today.) |

## 5. Control flow

1. **Materialize** (`Specs.materialize_spec`, dispatch). The Resolver returns the
   descriptor; if the subscription has `suppress_unchanged?`, compute `body_hash`
   over `dedup_on` (if the transform set it) else the body, and store it on the
   `pending` spec. (Costs one hash per materialized delivery for opted-in subs only.)
2. **Schedule / suppress** (`Scheduler.promote/1`). When the scheduler picks a
   lane's head to promote, it decides per head:
   - if the head carries a `body_hash` (i.e. its subscription opted in) **and** that
     hash equals the lane's last delivered body (`Dedup.last_delivered_hash/1`), it
     runs the **`:suppress`** action — `pending → :suppressed` — which writes the
     `:suppressed` log and emits `[:ash_integration, :dedup, :suppressed]` telemetry
     (**failure counters left untouched** — see §5.1). The lane's in-flight slot is
     never taken; the next head promotes on the following pass.
   - otherwise it runs **`:schedule`** (`pending → :scheduled`) as before.

   Both transitions push `WHERE state = 'pending'` at the call site (the read→write
   guard), and the partial unique index remains the one-in-flight backstop.

   **Why here.** The scheduler only promotes a head when the lane's slot is free, so
   the previous head is already terminal and the baseline is determinate (§2.2). A
   suppressed row therefore never becomes `:scheduled`, never enters the delivery
   relay, never claims a lease or bumps `attempts`, and never occupies the lane's one
   in-flight slot. Deciding "is this state even worth delivering?" *is* a scheduling
   decision; the delivery relay stays purely about sending and is unchanged by this
   feature.
3. **Send** (`Delivery.Relay`). Only `:scheduled` rows reach it; it delivers and
   records the result (lease-token fenced). Suppression is not a relay concern.

### 5.1 Two ways suppression must not lie to operators

The whole point of a distinct state is to keep monitoring honest, which forces two
rules:

- **`delivered` means bytes went out; `:suppressed` is its own bucket.** "Last
  `delivered`" stays a truthful answer to *"when did we last actually send to this
  target?"* A lane that suppresses for an hour shows an hour-old last-delivered and
  a fresh last-suppressed — the operator sees reality, not false-green. `:suppressed`
  is *also* distinct from `cancelled` (which means superseded/dropped): suppression
  means *"the consumer is already up to date,"* a positive outcome, not a loss.
- **A suppression does not reset the failure counters.** A real `delivered` resets
  `consecutive_failures` on both the connection and subscription *because it proves
  the transport accepted bytes*. A suppression touches no transport, so it proves
  nothing about health — resetting on it would mask a degrading endpoint (the same
  false-green failure mode). Suppression is **neutral**: it neither bumps nor resets.
  The next *real* delivery is what moves the counters.

`:suppressed` is terminal and leaves the lane like `delivered`, so the scheduler is
unchanged (it never schedules terminal rows). Retention reaps it alongside the other
terminal states. The cost is the new state's surface: the state enum, the reaped set,
and the dashboard's state filters/badges all gain one member.

## 6. Why we do NOT fix #1 (in-transaction event redundancy) at capture

Nested-action re-capture is **write-amplification, not a correctness bug**, and the
system already has the right absorbers:

- **Coalescing** collapses same-key `pending` siblings to the newest, so two
  `Event`s from nested actions already yield **one** delivery for a default
  subscription.
- **Content suppression** (this doc) absorbs the rest — even a
  `notify_on_every_change` subscriber drops an identical second snapshot on the
  wire.

Trying to dedup `Event`s *at capture across nested actions* fights the
architecture: `after_batch` is per-action, so cross-action dedup in one transaction
needs a **transaction-scoped accumulator** (process dictionary or txn-local
context) — fragile, explicitly discouraged in this codebase, and corrosive to the
immutable-outbox model where **each action's snapshot is a true fact** worth
recording even when two facts happen to be equal.

If the *capture cost* (not the wire redundancy) is ever the real problem, the
existing levers are better and producer-local: the deferred "lite produce + async
enrich" fallback, and letting `produce/3` return `{}` for a record whose before-image
equals its after-image (the producer already has the before-image in
`changeset.data`). Neither is part of this feature.

## 7. The honest limit: dedup ≠ delta detection

Content suppression gives *"suppress identical consecutive states"* — state-sync
semantics that fit the snapshot model. It does **not** give *"fire specifically
when field X transitions, even if the rest of the body differs for unrelated
reasons."* That is **delta/change detection**, which needs the **before-image**
persisted (producers have it in `produce/3` but don't store it), and is already
listed under "Deferred" in the architecture doc (§14, incremental/delta events).

The boundary in practice:

- Subscriber projects only `{status}` and wants "ping me when status changes" →
  **content suppression nails it** (identical projection ⇒ suppressed).
- Subscriber wants "ping me when `status` changes but send the *whole* record" →
  **out of scope** (the whole record differs for unrelated reasons; that's the
  deferred delta feature).

Documenting this boundary keeps us from overselling #2.

## 8. Edge cases

- **No baseline (first delivery, or baseline reaped by retention).** Retention trims
  terminal deliveries after `delivery_days` (default 90). If the last `delivered`
  row for a quiet lane is reaped, the next identical change finds no baseline and
  **delivers once** — degrades *safely* (at-least-once already permits a redundant
  send), then re-establishes the baseline.
- **Coalescing + suppression together.** Coalescing runs first (collapse pending
  pile-ups to the latest), suppression second (drop the latest if unchanged). They
  key on the same `(subscription, event_key)` and never conflict.
- **`dedup_on` returns nil / non-encodable.** Treat a nil/blank `dedup_on` as
  "fall back to body"; a non-encodable term parks the delivery with a readable error
  at the resolver boundary (same trust-boundary treatment as other invalid transform
  output), rather than silently disabling suppression.
- **Reprocess.** Re-resolving a delivery recomputes `body_hash` from the immutable
  `Event` exactly as it recomputes the descriptor — no special handling.
- **Poison / parked rows.** No `body_hash`, never suppressed; unchanged behavior.

## 9. Observability

- Telemetry `[:ash_integration, :dedup, :suppressed]` with
  `%{subscription_id, event_type, event_key}` — mirrors the coalesce telemetry.
- A delivery-log row for each suppression (so the dashboard's events → deliveries →
  logs drill-down shows "suppressed, identical to last delivery" alongside real
  sends), and the distinct `:suppressed` state on the row.
- The dashboard should surface **last *delivered*** (real send) separately from last
  activity, so suppression can't visually stand in for a send. A high
  suppressed-to-delivered ratio is a *useful* signal (the subscription is mostly
  steady-state), not a healthy/unhealthy one on its own.

## 10. Rollout

1. Add `suppress_unchanged?` (Subscription) + `body_hash` (EventDelivery) attributes
   and the `:suppressed` state + `:suppress` action; generate the migration.
   Default-off changes nothing.
2. Compute + store `body_hash` at materialize for opted-in subscriptions; plumb
   `dedup_on` out of the Lua result in the Resolver (strip from the wire descriptor).
3. Decide suppression in the **scheduler** (`promote/1`): per ready head, `:suppress`
   (baseline lookup matches) vs `:schedule`; the `:suppress` action writes the log +
   telemetry and **does not** reset failure counters. The delivery relay is unchanged.
4. Update everything that enumerates delivery states (retention's reaped set,
   dashboard state filters/badges, read-action `state` constraints) to include
   `:suppressed`.
5. Docs: the delivery-pipeline guide gets a "Content Suppression" section stating
   body-only + the `dedup_on` escape hatch + the dedup-vs-delta boundary; the
   producers guide notes that field-level subscription is projection + suppression.

## 11. Alternatives considered

| Alternative | Why rejected |
|---|---|
| Config enum `hash: body \| body+headers \| all` | Only `body` is ever a safe default (`event-id` poisons headers); an enum with one good answer is a trap. `dedup_on` serves the rare case precisely. |
| Suppress at **dispatch** (vs. last *materialized*) | Cheaper, but the baseline is a possibly-stale sibling, not the last *delivered* — violates the stated requirement. Revisit only if dispatch volume forces it. |
| Suppress in the **delivery relay** (at claim / in a batcher) | Works, but a suppressed row first becomes `:scheduled`, gets claimed (lease + `attempts` bump), and briefly holds the lane's one in-flight slot — a no-send row masquerading as a delivery — before being flipped. The scheduler already knows the prior outcome at promote time (one in-flight per lane), so deciding there sends it straight `pending → :suppressed` and leaves the relay untouched. |
| `delivered` + `suppressed?` boolean (instead of a `:suppressed` state) | Overloads `delivered`, the one signal an operator reads as *"bytes went out."* Every operational query/metric would then have to remember `AND suppressed? = false`, and a quiet suppressing lane would show false-green. A distinct state is honest by construction. (We also found suppressed rows never need to be in the baseline — see §4 — so the boolean bought nothing.) |
| Per-`(subscription, event_key)` cursor table holding `last_delivered_hash` | Unbounded extra table to maintain + reap; the existing `delivered` rows already are the cursor (indexed, retained, ordered). |
| Resetting failure counters on a suppression | A suppression touches no transport, so it proves nothing about endpoint health; resetting would mask a degrading target (false-green). Suppression is neutral (§5.1). |
| Set-membership dedup ("never send a body we ever sent") | Breaks legitimate state recurrence (`5 → 6 → 5`). Must be last-delivered only. |
| Transaction-scoped capture dedup (fix #1 at source) | Fragile accumulator, fights the immutable outbox; coalescing + suppression absorb #1 downstream. |
| A "watched fields" DSL for #2 | Redundant — field selection is the projection the author already writes; suppression of that projection *is* field-level subscription. |
