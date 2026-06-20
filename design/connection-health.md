# Connection Health: Derived Suspension & Bounded Probes (Design Doc)

**Status:** Complete, phased (§13). Schema groundwork (`failure_class` + window
indexes) **landed in #41** (phase 0); the **derived recompute + park + removal of
`consecutive_failures`** in **#45** (phase 1); the **single-sourced, Ecto**
schedulable-head query in **#46** (phase 2); the **bounded recovery probe** — a
second caller of that query, restoring automatic recovery — is **this PR** (phase 3).
· **Scope:** replacing the outbound suspension
mechanism — today an incrementally-maintained `consecutive_failures` counter plus a
*manual* unsuspend — with a **derived, windowed** health signal recomputed from the
delivery `Log`, a **park-on-suspend** step that frees delivery capacity, and a
**bounded probe** that gives sound automatic recovery. Outbound only. Pre-1.0; no
backward-compatibility constraints.

> Internal maintainers' doc. It assumes the [outbound
> architecture](outbound-architecture.md) — `Event` vs `EventDelivery`, the
> `(connection, event_key)` lane, the scheduler (promotes `pending → scheduled`,
> owns ordering) and the delivery relay (claims `:scheduled` rows, sends them),
> the soft-lease/claim/fence mechanics, and the two-level
> connection-vs-subscription suspension classifier. This is the *why*; the guides
> are the *how*.

---

## 1. Summary

Suspension today is an **event-sourced counter**: every delivery failure bumps
`consecutive_failures` on the `Connection` (transport failures) or the
`Subscription` (response rejections), and at a threshold the row flips
`suspended = true`. Recovery is **manual** — an operator calls `unsuspend`.

Two problems motivate the redesign:

1. **A hot-row write on the worst path.** Every failure to a connection
   contends on that connection's single row to `inc: [consecutive_failures: 1]`
   (`OnDeliveryFailure.bump_and_maybe_suspend/4`) — serializing all of a
   connection's failures on one row's lock *exactly* when it's failing in
   bursts.
2. **Manual unsuspend is operationally unsound.** Forgetting to unsuspend leaves
   an integration frozen indefinitely; remembering it releases the whole backlog
   in one flood into an endpoint that may still be unhealthy.

The redesign replaces the counter with a **periodically recomputed** signal —
*"a connection with no successful delivery among its last N transport attempts is
suspended"* — written to the existing `suspended` column **only on transition**,
so the hot-path write disappears and the scheduler/dashboard keep reading
`suspended` unchanged. Recovery becomes automatic and *sound* via a **probe**:
while suspended, a connection gets exactly one delivery at a time (bounded across
all suspended connections), and a probe **success** is what clears the
suspension on the next recompute — recovery is *observed*, never assumed from the
silence of not-trying.

Three load-bearing pieces, each independently simple:

1. **Derived trip signal** (§5) — recompute `suspended` from the `Log`; drop
   `consecutive_failures`.
2. **Park-on-suspend** (§6) — when a connection transitions to suspended, revert
   its *un-leased* `:scheduled` rows to `pending` so the relay stops burning
   delivery slots on a dead endpoint.
3. **Bounded probe** (§7) — a separate, infrequent tick that lets one delivery
   through for a bounded, round-robin set of suspended connections, **reusing the
   scheduler's own schedulable-head selection** so a probe is held to the exact same
   ordering gates as a normal promotion (§7).

**Phasing (§13).** Pieces 1 and 2 ship first (PR #45). Until the probe lands,
recovery stays **manual** — the retained `unsuspend` action, exactly as today — so
phase 1 is a strict improvement on the hot-row write and slot-pressure axes and
*neutral* on recovery (it does not regress to "frozen forever": an operator
unsuspends just as before). The probe (automatic recovery) is phase 3, after a
phase-2 refactor that makes it correct *by construction* rather than by a hand-copied
subset of the scheduler's gates (§7).

## 2. The capacity model this rests on

The design is shaped by three facts about the existing pipeline; getting them
wrong is how the naive versions fail.

| Fact | Source | Consequence |
|------|--------|-------------|
| A "lane" is `(connection_id, event_key)`, created dynamically, **at most one in-flight** (`:scheduled`) row each. | partial unique index `(connection_id, event_key) WHERE state = 'scheduled'` | There is **no bound on the number of lanes**, only on per-lane concurrency. |
| The real concurrency ceiling is the delivery relay's Broadway `concurrency` — **default 25**. | `Delivery.Supervisor` opts (`concurrency`) | At most ~25 sends in flight *for the whole system*. This is the scarce resource everything competes for. |
| The relay claims `:scheduled` rows **oldest-first**. | `Dispatcher.claim/1` (`ORDER BY event_id ASC`) | A failing connection's backlog is the *oldest* work, so it is claimed *first* — and a dead-but-hanging endpoint holds its slot for the full lease (`http_max_timeout + 30s`). Unbounded probing of sick connections **starves** healthy traffic. |

**The gap in today's behavior.** Suspension is enforced *only* in the scheduler
(`find_schedulable_events` filters `d.suspended = false`), which gates
`pending → scheduled`. `Dispatcher.claim/1` **never looks at `suspended`**. So a
suspended connection's already-`:scheduled` backlog keeps being claimed and
retried (on backoff) until each row poisons — suspension stops *new* promotions
but never relieves the slot pressure that is the whole point of suspending. §6
closes this gap. (`:parked` is unrelated — it is the *build-failure* state
awaiting `:reprocess`, not a suspension mechanism.)

## 3. Goals & non-goals

**Goals.** Remove the per-failure hot-row write. Make suspension a sound,
self-healing signal with no manual step on the happy path. Free delivery
capacity the moment a connection is suspended. Never let recovery probing starve
healthy traffic. Preserve delivery ordering and the existing fence/lease
guarantees. Keep the hot scheduling query a one-line change.

**Non-goals.** Inbound transports (none can fail at the transport layer yet —
this is purely outbound). Replacing the **poison** terminal policy (a row stuck
at the attempt ceiling is still left `:scheduled`, lane blocked, human-resolved —
unchanged). Removing **manual** operator control (kept — §8).

## 4. The two health scopes

The current classifier splits failures by blast radius, and the derived model
keeps that split — it changes only *how* each scope's `suspended` flag is
computed:

| Scope | Trips on | Blast radius |
|-------|----------|--------------|
| **Connection** | **transport** failures (couldn't reach the target: conn refused, DNS/TLS, timeout, broker down) | every subscription on the connection |
| **Subscription** | **response** rejections (target answered 4xx/5xx) | just that one subscription's lane(s) |

This doc specifies the **connection** scope in full; the subscription scope uses
the identical mechanism over its own slice of the `Log` (§10). The split means
the recompute must be able to distinguish transport from response outcomes in
the `Log` — see §5.

## 5. Derived trip signal

**Definition.** A connection is suspended iff **none of its last `N` transport
delivery outcomes succeeded** — i.e. the most recent `N` transport-class `Log`
rows for the connection are all failures (with `N ≥` the same threshold the
counter used). This is the *consecutive-failure* breaker the team already trusts,
recomputed from the durable record instead of maintained as a counter — so the
trip *semantics* are unchanged; only the storage and the recovery half change.

**Why "last N attempts" and not "X in Y minutes."** A raw count over a time
window is volume-sensitive: a high-throughput connection trips fast, but a
low-volume connection to a genuinely dead endpoint may never accumulate `X`
failures inside `Y` minutes and would hammer forever. "No success in the last N
*attempts*" has no such blind spot — it trips on a run of failures regardless of
how long that run took.

**Computation.** A periodic check (every few minutes) recomputes the suspended
set per scope from the `Log` and writes `suspended` **only where it changed**:

- For each connection, inspect its most recent `N` transport-class outcomes; if
  zero are successes → should-be-suspended.
- Diff against the current `suspended` column; issue a **filtered** update for
  each transition (`suspend` where `suspended == false`, `unsuspend` where
  `suspended == true` and the connection is no longer in the set). The filter
  makes concurrent recomputes on multiple nodes idempotent — the same pattern
  `OnDeliveryFailure.maybe_suspend/6` already uses.

This replaces the per-failure `inc` with a **per-transition** write: rare, off
the hot path, and bounded by the number of connections actually flipping state.

**`Log` requirement (landed in #41).** The recompute must tell transport failures
from response rejections and from successes. The discriminator is now in place: a
nullable **`failure_class`** column on the `Log` (`:transport` / `:response`, nil
on non-failures), persisted from the same class `OnDeliveryFailure.classify/1`
already computes — so the row's class always matches the breaker's decision.
Successful deliveries log `status: :success`; failures log `status: :failed` — so
a "no success in the last `N`" recompute keys off `status: :success` being absent
from the scope's most recent `N` rows.

**`consecutive_failures` is removed** from both `Connection` and `Subscription`
(attribute, the `inc`, the `record_success` reset). `suspended` /
`suspended_at` / `suspension_reason` **stay** — now *derived/cached* (written on
transition) rather than source-of-truth-by-accumulation. `suspended_at` becomes
"when the recompute last flipped it on," useful for the dashboard.

**Query cost & indexing (the `Log` can get large).** The recompute reads from
the delivery `Log`, which is the highest-volume table in the system, so the
naive shape of this query is the thing to avoid. The recompute is **not** a scan
of the whole `Log` and **not** a `GROUP BY connection_id` over all history —
either of those is `O(table size)` and degrades as the `Log` grows. It is a
**top-N-per-group** read: *for each connection being evaluated, seek to its most
recent `N` transport-relevant outcomes and stop.* With a supporting index this is
`O(connections_evaluated × N)` index reads — **independent of how big the `Log`
is** (a 100M-row `Log` costs the same per pass as a 1M-row one, because you never
read past the `N`th row of any connection).

**What "transport-relevant" means for the window — and why successes can't be
excluded.** A connection's transport window is its **successes ∪ transport
failures**; **response** rejections (4xx/5xx — the target answered) are *not*
transport outcomes and are excluded (they drive the *subscription* scope, §10). A
success has no `failure_class` (it's not a failure), but it is the very thing that
*clears* the breaker — "no success among the last `N`" can only become false if
successes are *in* the window. So the window predicate is
`status = 'success' OR failure_class = 'transport'`, **not** `failure_class =
'transport'` alone — the latter would exclude every success and freeze a tripped
connection suspended forever. (A delivery success proves both transport *and*
response health, so one success row legitimately counts in both scopes' windows.)

Three things make the cost bound hold:

- **The supporting index already exists (#41) — the pre-existing ones don't
  serve it.** The `Log` was previously indexed on `(connection_id)`,
  `(created_at)`, and `(connection_id, event_key, created_at)`. The composite
  looks usable but is not: `event_key` sits **between** `connection_id` and the
  recency key, so it orders a connection's rows by key *then* time — to read a
  connection's rows in pure recency order you would have to scan **all** of its
  rows across every `event_key` and re-sort (the full-history sort, on exactly
  the high-volume connections we care about). So #41 landed the partial,
  scope-keyed, recency-ordered index this recompute needs:

  ```sql
  -- landed in #41 (outbound_logs_conn_transport_health_idx)
  CREATE INDEX ... ON <log> (connection_id, id)
    INCLUDE (status)
    WHERE status = 'success' OR failure_class = 'transport';
  ```

  **Ordered by `id`, not `created_at`** — the `Log`'s `id` is a uuidv7
  (time-ordered) and is *already* this table's recency key (both read actions
  sort `id: :desc`), so keying the health windows on `id` keeps one ordering
  notion for the table. It also gives a **unique total order** (no
  same-microsecond tie ambiguity that could flap "the last `N`"), and for the
  `Log` the row *is* the outcome, so `id` is occurrence-ordered — the scheduler's
  "delivery `id` is *dispatch*-time, not a valid ordering key" caveat is about
  `EventDelivery` and does **not** apply here. (`created_at` stays on the row —
  retention filters on it — it just isn't the health-index key.) `INCLUDE (status)`
  keeps the success check index-only.

  Given that index, the signal can alternatively be reduced to *two* seeks per
  connection rather than fetching `N` rows — the most-recent success (a
  `WHERE status = 'success'` partial) vs. the count of transport failures since it
  (a `WHERE failure_class = 'transport'` partial); suspended iff that count `≥ N`
  — but that is an optimization detail; the load-bearing point is that the cost is
  `groups × N` seeks, not table size.

- **Only recently-active connections are evaluated.** The set per tick is
  (currently `suspended`) ∪ (a connection with a transport-relevant `Log` row
  since the last recompute). The first is bounded by the suspended set; the second
  is one recency-ordered scan of the recent `Log` tail (the PK on `id`, the
  `(created_at)` index, or the partial above) to collect the touched
  `connection_id`s. So `groups` is bounded by *recent activity*, never the catalog
  size.

- **The `Log` is retention-bounded.** `Outbound.Retention` already trims `Log`
  rows older than its (shorter) `delivery_days` window, oldest-first, so the
  table has a ceiling set by the retention policy rather than growing without
  bound.

Net: the recompute is cheap *given the index* (which #41 already landed), runs
every ~60s off the hot path, and its cost is set by recent activity, not by `Log`
size.

## 6. Park on the suspend transition

When the recompute flips a connection to `suspended`, immediately stop the relay
from spending the scarce 25 slots on it. The relay claims any `:scheduled` row
regardless of `suspended` (§2), so we **revert the connection's un-leased
`:scheduled` rows back to `pending`** in one filtered statement:

```sql
UPDATE <event_delivery> SET state = 'pending', claimed_at = NULL
WHERE connection_id = $1
  AND state = 'scheduled'
  AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $lease))
```

`$lease` is exactly `Delivery.Supervisor.lease_seconds/0` — the same soft-lease
window `Dispatcher.claim/1` uses to decide a row is free. The predicate is the
claim's own "is this row free?" test, so it reverts precisely the rows **no live
worker holds**:

- `claimed_at IS NULL` — promoted but never claimed.
- `claimed_at` older than the lease — an abandoned/expired claim (worker
  crashed).
- `claimed_at` *within* the lease — **a worker is actively sending it** → left
  alone. You cannot un-send an in-flight request; reverting it would risk a
  double send.

**Fence safety.** If a worker whose lease we treated as expired later finalizes a
row we reverted, its finalize is fenced on the old `claimed_at` token while the
row is now `pending`/`claimed_at = NULL` → the update matches nothing, a clean
no-op. Identical to ordinary lease-expiry-then-reclaim; no new failure mode.

**Drain, don't abort.** The live-leased rows finish their send and terminate
normally. Because the connection is now suspended, the scheduler promotes no new
head into those lanes, so each lane goes idle after its in-flight row completes.
Within one lease window the connection has **no active delivery work** except the
probe (§7). The reverted `pending` rows keep their place; on un-suspension the
scheduler re-promotes them oldest-first, ordering intact.

This park runs **only on the transition** (rare), not per failure — so it does
not reintroduce the write pressure §5 removed.

## 7. The bounded probe

Recovery needs *observed* success, which needs traffic — but §2 forbids
unbounded traffic to sick connections. The resolution is a **separate, infrequent
tick** that owns the *policy* (which suspended entities to probe, how many, in what
order) while **delegating the *mechanism* (turning a `pending` row into a
`:scheduled` one) to the scheduler** — see "Promotion is the scheduler's job"
below. The policy half:

- Each probe tick, pick **at most `M` suspended connections, round-robin**
  (oldest-probed-first) — *not* random (random has a starvation tail that delays
  noticing a recovered connection far beyond `M` passes) and *not* the whole set
  (a broad outage suspending 500 connections would dump 500 oldest rows into 25
  slots and hang them on timeouts). `M` is a small knob, `≪ 25`, so probes never
  dominate the pool; it trades probe pressure against mass-recovery latency.
- **The round-robin cursor is derived from the `Log`, not held in process
  state.** "Oldest-probed-first" = order the suspended set by *the `id` of
  each connection's most recent transport `Log` row*, ascending. For a suspended
  connection that row **is** its last probe — park (§6) guarantees a suspended
  connection has no other transport traffic — so the `Log` already records when
  we last probed it; no `last_probed_at` column and no in-memory cursor are
  needed. That `id` (a time-ordered uuidv7) is a **byproduct of the §5 recompute**,
  which already reads each connection's most recent transport-relevant rows over
  the very index that scan requires (`(connection_id, id DESC) WHERE status =
  'success' OR failure_class = 'transport'`); the probe order falls out of the same
  read at no extra cost. A
  persisted `last_probed_at` was considered and rejected: it would not avoid the
  recompute's `Log` read (unavoidable for the signal itself), so it buys nothing
  on reads while adding a write and a column — strictly the worse trade.
  Deriving the cursor from the `Log` also makes round-robin fairness **exact
  across any number of nodes** (every runner reads the same authoritative
  timestamps), which removes the only reason §9 had to prefer a singleton.
- For each picked connection, ensure it has **exactly one live (non-poison)
  `:scheduled` probe**: if it has none, ask the scheduler to promote **one**
  schedulable head for it (the "Promotion" subsection below). That single row is
  then claimed and sent by the **normal relay** — no special claim path, because
  after the park (§6) the connection has no *other* `:scheduled` rows competing.
- A probe **success** writes a `status: :success` `Log` row; the next recompute
  (§5) sees a success in the last `N` and **unsuspends** the connection, after which
  the scheduler resumes normal promotion in order. A probe **failure** backs off
  (its `next_attempt_at`) and the connection stays suspended; the row self-paces
  as the probe until it succeeds or poisons.
- If a connection's probe row **poisons** before the endpoint recovers, the pass
  promotes a fresh `pending` head next tick so the connection always has a live
  probe (a poison row alone would strand it, unable to ever observe recovery).

Probe load is therefore bounded by `M` single deliveries per tick, **independent
of how many connections are suspended** — the property the naive
"budget-1-per-connection" lacked.

### Promotion is the scheduler's job — the probe must not re-derive it

A probe promotion is **the same state transition the scheduler owns** (`pending →
scheduled`), restricted to the set the scheduler deliberately excludes
(`suspended = true`). It is therefore subject to **every** ordering gate a normal
promotion is, with no exceptions:

- the **lane head** rule (an older `pending`/`parked` sibling on the same
  `(connection_id, event_key)` blocks the lane — never promote past a parked head);
- the **one-in-flight-per-lane** slot-free check;
- the **high-water gate (#56)** — never promote a head while an older same-key
  Event is still undispatched;
- the **other scope's suspension** — a connection probe must not promote a row whose
  *subscription* is response-suspended, and vice-versa.

The first cut of this design under-specified promotion as "just promote one
`pending` head (its oldest)." That is **wrong**: it silently drops every gate but
the slot-free check, so a probe could deliver out of order past a parked head or an
undispatched older event, or send to a response-suspended subscription. Re-deriving
even a "careful" subset of the gates in the health module is the root cause — it is
a *second copy of correctness-critical logic* that will drift from the scheduler's.
We do not sacrifice correctness for a recovery probe, and we do not duplicate the
gates to get it.

So the gate logic stays **single-sourced in the scheduler**, and the probe is just
a second caller of it:

- The scheduler's schedulable-head query is refactored so its **suspension
  predicate is its one parameter**; every other gate is fixed and shared. The
  normal sweep passes `suspended = false` for both scopes; the probe passes "this
  scope relaxed for these `M` ids, the other scope still `false`." Both run the
  *identical* gate set — the probe cannot diverge because it is the same query.
- **Bounding is policy, not a gate**, so it composes *on top* of the shared query
  (one head per entity, `≤ M` per tick, round-robin by the `Log` cursor) without
  touching the correctness core.

This split is why the probe was deferred past phase 1: **phase 2** refactored the
scheduler query to the single-parameter, composable form (#46), and **phase 3** adds
the probe as its second caller (`Scheduler.promote_probe/2`). Shipping the thinner
promotion with phase 1 would have been incorrect.

## 8. Manual control is preserved

Derived suspension is *automatic* health. Operators still need to (a) pause a
healthy connection for maintenance and (b) force one back. That is the existing
**`active`** flag (`activate`/`deactivate`), which is orthogonal:

> **effective-deliverable = `active` AND NOT `suspended`**

`active` is the human switch (never touched by the recompute); `suspended` is the
derived health. A forced recovery is `deactivate`-then-`activate`, or simply
fixing the endpoint and letting the probe clear it. The old manual `unsuspend`
action can stay as an operator override that clears `suspended` early (the next
recompute will re-set it if the connection is still failing), but it is no longer
*required* for recovery.

## 9. Cross-node behavior

**This is a library, so it must be cluster-*friendly* without assuming a
cluster.** It ships as a dependency of a host app whose topology we don't
control — one node or fifty, BEAM-distributed or just several independent nodes
sharing the one Postgres. We cannot impose an election mechanism (`:global`,
Horde, `libcluster`) on the host, and nothing here may *depend* on one for
correctness. The only coordination primitive we can assume is the one the
library already requires: **the database.**

**Two jobs, two coordination needs.** The scheduler today does one thing —
**promotion** (`pending → scheduled`) — and this design adds two more — the
**health recompute** (§5) and the **probe pass** (§7). They are not the same kind
of work and should not be forced to share a placement decision:

| Job | Latency | Coordination need | Placement |
|-----|---------|-------------------|-----------|
| **Promotion** | latency-sensitive — poked by deliveries finishing via a local `GenServer.cast` (`Scheduler.notify/0`) | none; idempotent via the partial unique index `(connection_id, event_key) WHERE state = 'scheduled'` | **per-node**, unchanged |
| **Recompute + probe** | periodic (~60s / ~30s), *not* latency-sensitive | idempotent via filtered transition writes + `SKIP LOCKED` | per-node *or* an optional single-runner |

**Promotion stays per-node — do not singleton it.** It is correct under `K`
concurrent runners by construction (the unique index makes double-scheduling
impossible — see the scheduler moduledoc), and being per-node is a *feature*:
each node self-pokes via a **local** cast with no network hop and no dependency
on a remote process being up. Making promotion a singleton would actively
regress two things: (1) `Scheduler.notify/0` is a cast to the **locally**
registered `name: __MODULE__`, so on every non-leader node it would resolve to an
unregistered name and be **silently dropped** — those nodes would lose
low-latency scheduling and fall back to the 10s idle sweep unless `notify` is
also rewritten into a distributed send; and (2) it introduces a *zero-runner*
gap during elections/failover that the per-node design simply does not have.

**Recompute + probe are the only candidates for a single runner — and even
there it is an optional optimization, not a correctness requirement.** Because
the cursor is derived from the `Log` (§7), `K` concurrent recompute/probe passes
are **correct, only redundant**; every shared-state mutation is already
concurrency-safe:

- **Recompute transition writes are idempotent.** Each runner computes the same
  set from the same `Log` and issues the same *filtered* update
  (`suspend WHERE suspended == false`, `unsuspend WHERE suspended == true`). The
  filter makes the second writer's update match zero rows — a clean no-op — so
  the worst case is a redundant scan, never a double-flip or a lost transition.
  (Same guard `OnDeliveryFailure.maybe_suspend/6` already relies on.)
- **Probe claims dedup via `SKIP LOCKED`.** Two runners picking the same
  suspended connection race on the same `:scheduled` probe row; `SKIP LOCKED`
  hands it to exactly one. The connection gets one or two probes that tick
  instead of one — bounded, harmless. Aggregate probe load under `K` runners is
  `≤ K × M` deliveries/tick, still small and self-correcting.
- **The probe cursor is shared, not per-process.** Because round-robin order is
  derived from each connection's most recent transport `Log` row (§7), every
  runner reads the *same* authoritative ordering — fairness is exact across any
  node count, with no in-memory cursor to diverge.
- **Park reverts are idempotent and fence-safe.** The un-leased-rows revert (§6)
  is a filtered UPDATE; a second runner finds the rows already `pending` and
  matches nothing. Live-leased rows are excluded by the lease predicate
  regardless of which runner runs it, and the fenced-finalize argument (§6)
  holds independent of how many runners exist.
- **`suspended` is a DB column,** so the suspended state itself is shared — every
  scheduler's `d.suspended = false` promotion filter sees transitions from
  whichever runner wrote them.

So the only cost of running the recompute/probe on every node is a duplicated
`Log` scan every ~60s (cheap — §5) and a `≤ K × M` probe load. **The default is
therefore per-node**: simplest, zero coordination, correct on one node or fifty.

**If duplicate scans ever measurably bite, the cluster-friendly way to make it a
single runner is a Postgres advisory lock** (`pg_try_advisory_lock`, or a
`FOR UPDATE SKIP LOCKED` "leader row") — one node grabs it and runs the periodic
tick, the rest stand by and retry. This assumes only Postgres (which the library
already requires), works whether or not the host runs BEAM distribution, and
auto-releases on connection drop. It is strictly preferable here to `:global` /
Horde, which would force a clustering assumption onto the host. And because the
lock-holder can still overlap briefly with a previous holder on failover, the
idempotency above is still what carries correctness — the lock only suppresses
the redundant scan, it does not let us delete any of the safety machinery.

Net: **promotion per-node always; recompute/probe per-node by default; a
Postgres advisory lock as an optional single-runner optimization, never a
correctness dependency.** Correctness rests on idempotent filtered writes,
`SKIP LOCKED`, fencing, and the `Log`-derived cursor — not on any election.

## 10. Subscription-scope reuse

The subscription scope (response rejections) is the **same mechanism** over a
different `Log` slice: "no `status: :success` outcome among this subscription's
last `N` response-class outcomes → `subscription.suspended = true`." Park applies per
subscription (revert that subscription's un-leased `:scheduled` rows); the probe
pass picks suspended *subscriptions* the same way. One health-recompute pass can
produce both scopes' transition sets in one sweep. Whether to land both scopes
together or connection-first is an implementation-sequencing choice (§13), not a
design fork.

## 11. Alternatives considered

| Alternative | Why not |
|-------------|---------|
| Keep the counter, add a **timed auto-unsuspend** (`suspend_until`) | Fixes recovery but not the hot-row write, and a fixed timer either releases into a still-dead endpoint (too short) or strands a recovered one (too long). The probe makes recovery *condition-based*, not time-based. |
| **"X failures in Y minutes"** window | Volume-sensitive: a low-volume dead endpoint never accumulates `X`-in-`Y` and hammers forever. "Last N attempts" trips on the run regardless of duration. |
| **Budget-1 probe per suspended connection** | Bounds per-connection but not *aggregate*: with many suspended connections their probes saturate the 25 oldest-first slots and starve healthy traffic. The bounded `M`-per-tick pass caps total probe load independent of set size. |
| **Random** probe selection | Starvation tail — an unlucky recovered connection waits far beyond `M` passes to be noticed. Round-robin bounds the worst case. |
| Probe by **un-suspending the connection for one pass** | Promotes *every* ready lane of the connection (one per `event_key`) → a burst of old rows into the slot pool. The probe must be a *single* delivery. |
| **Gate `claim` on `suspended`** instead of parking | Avoids the park write but then the probe must bypass the claim gate for one row (fiddly). Park-on-transition is one rare UPDATE and leaves claim untouched; the probe is just "promote one." |
| Leave already-`:scheduled` rows alone on suspend (today's behavior) | They keep being claimed on backoff and burn the 25 slots on a dead endpoint until poison — suspension fails to do the one thing it exists for. |

## 12. Failure & edge cases

| Situation | Outcome |
|-----------|---------|
| Connection fails its last `N` transport attempts | Next recompute sets `suspended`; park frees its un-leased slots; in-flight rows drain. |
| In-flight (live-leased) row at suspend time | Left to finish (can't un-send); lane idles after, no new head promoted. |
| Endpoint recovers | A probe succeeds → next recompute unsuspends → scheduler resumes oldest-first; reverted backlog drains in order. |
| Probe row poisons while still suspended | Pass promotes a fresh head next tick so a live probe always exists. |
| Recompute races across nodes | Filtered transition writes are idempotent; only one logs/telemetries each flip. |
| Operator override (`unsuspend`) on a still-sick connection | Clears `suspended` early; the next recompute re-sets it. Probe/health converge. |
| Many connections suspended (broad outage) | Probe load stays `≤ M` deliveries/tick; recovery discovery is `O(set / M)` passes — the `M` knob trades latency for pressure. |
| Poison (attempt ceiling) | Unchanged — left `:scheduled`, lane blocked, human-resolved. Not auto-resolved by the probe. |

## 13. Telemetry, config, and slices

**Telemetry.** Keep the existing `[:ash_integration, :connection, :suspended]` /
`:unsuspended` events, emitted on the recompute's transitions (diff old vs new
set) rather than inline on a failure. Add a probe event
(`[:ash_integration, :connection, :probe]` with the outcome) for visibility into
recovery attempts. The standing signals (count suspended, oldest-suspended age)
are dashboard aggregates, not telemetry.

**Config** (under the existing intent-named slices):

```elixir
config :ash_integration,
  health: [
    window_attempts:      5,        # N — failures-in-a-row to trip (was the suspension threshold)
    recompute_interval_ms: 60_000   # how often suspended sets are recomputed
    # phase 3 (probe) adds: probe_interval_ms: 30_000, probe_batch: 3 (M ≪ delivery concurrency)
  ]
```

Phase 1 ships only `window_attempts` and `recompute_interval_ms`; the probe knobs
arrive with the probe (phase 3), so dead config is never advertised.

`recompute_interval_ms` must comfortably exceed delivery latency, or a
recovering connection's in-flight probe success won't have landed in the `Log`
before the recompute re-evaluates and bounces it back into the set. The relevant
bound is not "typical" latency but the **worst-case probe duration**, which is
the soft-lease window — `Delivery.Supervisor.lease_seconds/0 = http_max_timeout +
30s` (§2). A probe that opens just before a slow endpoint's timeout can take the
full lease to resolve; if `recompute_interval_ms` is shorter than that, the
recompute can fire on a connection whose probe is still in flight and hold it
suspended for another whole interval. So `recompute_interval_ms` should be sized
against the deployment's actual `http_max_timeout` (a high max-timeout demands a
longer recompute interval, not the 60s default), and `probe_interval_ms`
similarly should not re-probe a connection whose previous probe is still
in-flight. These two intervals are **tuning constraints derived from
`http_max_timeout`**, not free-standing constants.

**Implementation phases.** Each phase is independently shippable and leaves the
system correct; recovery stays manual until phase 3.

- **Phase 0 — `Log` discriminator + window indexes — ✅ landed in #41.**
  `failure_class` persisted on the delivery `Log`, plus the two partial per-scope
  indexes (`(connection_id, id) … WHERE status='success' OR
  failure_class='transport'` and the `subscription_id`/`response` analog, `INCLUDE
  (status)`) that keep each top-`N`-per-scope read `O(groups × N)` as the `Log`
  grows (§5). Purely additive; no behavior change.

- **Phase 1 — derived recompute + park + removal — PR #45 (both scopes).** The
  periodic health pass computing `suspended` from the `Log` (§5), transition-only
  filtered writes, transition telemetry; the park-on-suspend revert (§6); and the
  removal of `consecutive_failures` (attribute, the `inc`, the `record_success`
  reset). Runs **per-node** (correct & redundant — §9). Recovery is **manual**
  (`unsuspend`), unchanged from today. *Verify:* a scope trips after `N` failures
  and clears after a logged success, with **no per-failure write**; on suspend,
  un-leased non-poison `:scheduled` rows return to `pending`, live-leased rows
  drain, poison rows stay, slots free.

- **Phase 2 — single-source the scheduler's schedulable-head query — this PR
  (enabler).** `find_schedulable_events` is refactored to `schedulable_heads/1`,
  whose **suspension predicate is its one parameter** (an Ecto `dynamic`); every
  other gate (lane head via `lane_heads/0`, slot-free, high-water #56, the other
  scope's suspension) is fixed and shared (§7). The normal sweep is the one caller,
  passing `both_healthy/0`. Pure refactor (no behavior change), and the query moved
  off raw SQL **to Ecto** — the host resources are queried as Ecto sources
  (`{table, resource}` / pinned resource modules). *Verified:* the full scheduler
  ordering suite (lane head, parked-head blocking, suspension, high-water #56,
  suppression) is unchanged.

- **Phase 3 — bounded recovery probe (both scopes) — this PR.** `Health.probe/0`
  picks `≤ probe_batch` suspended entities per scope (oldest-probed-first by the
  `Log` cursor, skipping any with a live `:scheduled` row) and calls
  `Scheduler.promote_probe/2`, which runs the **phase-2 query** with only that
  entity's own suspension relaxed (`d.id == ^id` / `sub.id == ^id`, the other scope
  still `false`), composes oldest-first + `limit(1)` on top, and force-`:schedule`s
  the head (no suppression — a probe must hit the transport). Adds
  `probe_interval_ms`/`probe_batch` config and `:probe` telemetry; restores automatic
  recovery. *Verified:* `M`-bounded load independent of set size; recovery via probe
  success; and — by reusing the shared query — **a probe never jumps a parked head,
  an undispatched older event (#56), or a response-suspended subscription** (covered
  by dedicated tests).

## 14. Open questions

- **`N` per scope or shared?** Transport flakiness and response rejection may
  warrant different thresholds. Start shared; split if a real workload asks.
- **Probe ordering vs. freshness.** The probe promotes the connection's *oldest*
  pending head. For a connection whose oldest rows are stale-but-still-wanted
  that's correct; if a host would rather probe with the *newest* (freshest
  payload), that's a per-connection policy knob — deferred until asked.
- **Dedicated probe capacity.** Probes currently share the 25-slot pool (bounded
  by `M`). If probe-vs-healthy contention ever bites under a very small pool, a
  tiny reserved probe concurrency lane is the upgrade path. Deferred.
- **Scheduler/recompute placement — decided (§9): per-node by default; promotion
  always per-node.** Promotion keeps its local-cast, per-node design. The
  recompute and probe run per-node too (correct-but-redundant via idempotent
  filtered writes + `SKIP LOCKED` + the `Log`-derived cursor), with a **Postgres
  advisory lock** held in reserve as an optional single-runner optimization if
  duplicate `Log` scans ever measurably bite. `:global`/Horde are explicitly off
  the table — a library must not impose a clustering mechanism on its host. Open
  sub-question: at what cluster size / `Log` volume the advisory-lock optimization
  is worth turning on — a measurement to take later, not a design fork now.
