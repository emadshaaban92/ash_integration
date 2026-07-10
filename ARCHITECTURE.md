# Architecture Map

> **Purpose.** A fast-start map for humans and AI agents: the mental model, the
> entry points, the load-bearing invariants, and where to look for things. It
> deliberately indexes the parts that the directory tree *can't* tell you — intent
> and invariants — and stays at the subsystem level so it ages slowly.
>
> **Keep it current.** See [Maintaining this file](#maintaining-this-file) at the
> bottom. If you change an entry point, an invariant, or a subsystem's
> responsibility, update this file in the same change.

## One-paragraph mental model

AshIntegration is an **outbound integration system**: it turns Ash resource
actions into named, versioned **event types** (`product.created`, `stock.changed`)
and delivers them to external systems over HTTP, Kafka, email, or WhatsApp. It is
an **event-driven state machine with at-least-once delivery**. The immutable
`Event` log is the durable source of truth (a transactional outbox); two disposable
Broadway relays claim rows directly from Postgres and drive them forward. The unit
on the wire is the event type, not the internal resource/action — this decouples
the public contract from the Ash data model.

## The pipeline (the spine of the whole system)

```
Source action ──► capture ──► dispatch relay ──► scheduler ──► delivery relay ──► transport
   (Ash)          (Event)     (EventDelivery)    (promote)      (send + retry)     (HTTP/Kafka/…)
```

| Stage | What happens | Start reading here |
|-------|--------------|--------------------|
| **Capture** | A `PublishEvent` change (injected into the source action's transaction) runs each subscribed producer's `produce/3`, writing immutable `Event` rows. No per-event job — the table *is* the outbox. | `lib/ash_integration/outbound/capture/publish_event.ex`, `.../capture/event.ex` |
| **Dispatch** | Broadway relay claims undispatched `Event`s (`FOR UPDATE SKIP LOCKED` + lease), runs the producer's `project/3` (authorize + route + redact) and the Lua transform, resolves + signs the descriptor, creates `EventDelivery` rows, stamps `Event.dispatched_at`. | `.../outbound/dispatch/relay.ex`, `.../dispatch/dispatcher.ex` |
| **Schedule** | `EventScheduler` GenServer (adaptive ~1s busy / 10s idle) skips suspended/parked lanes, honors the high-water gate, and promotes the oldest `EventDelivery` per `(connection, event_key)` to `scheduled`. Owns *all* scheduling decisions. | `.../outbound/delivery/scheduler.ex` |
| **Deliver** | Broadway relay claims `:scheduled` rows (soft lease + attempt bump), sends them, and reports the outcome. The relay is "dumb" — it only executes and classifies; the scheduler decides what runs next. | `.../outbound/delivery/relay.ex`, `.../delivery/dispatcher.ex` |
| **Transport** | The actual send. Wire envelope + transport dispatch, then per-protocol adapters and their auth/signing/security config. | `.../outbound/wire/transports/`, `.../transport/` |

The `EventDelivery` state machine (`pending → parked/scheduled → failed → delivered/cancelled`)
lives in `.../outbound/delivery/event_delivery.ex`. Its state table and full
transitions are documented in the README `## Architecture` section and
`design/delivery-retry-model.md`.

## Subsystem map

| I want to… | Go to |
|------------|-------|
| Understand how resources declare event types (the DSL) | `lib/ash_integration/outbound/declare/` (`source.ex`, `producer.ex`, `registry.ex`, `dsl/`) |
| Trace event capture | `lib/ash_integration/outbound/capture/` |
| Work on dispatch (Event → EventDelivery) | `lib/ash_integration/outbound/dispatch/` |
| Work on scheduling / ordering / retry timing | `lib/ash_integration/outbound/delivery/scheduler.ex`, `.../delivery/changes/`, `.../delivery/validations/` |
| Work on the delivery relay / sending | `lib/ash_integration/outbound/delivery/relay.ex`, `.../delivery/route/` |
| Work on Lua transforms | `lib/ash_integration/outbound/delivery/transform/` (`runtime/lua.ex`, `limits.ex`, `preview.ex`) |
| Add or change a transport | `lib/ash_integration/outbound/wire/transports/` **and** `lib/ash_integration/transport/` (config, auth, signing, TLS, adapters) |
| Change request signing | `lib/ash_integration/transport/signing/` (+ `design/configurable-signing.md`) |
| Work on connection/subscription health & suspension | `.../delivery/health.ex`, `.../delivery/parked_health.ex` (+ `design/connection-health.md`) |
| Work on the dashboard UI | `lib/ash_integration/web/live/outbound/`, `.../web/router.ex`, `.../web/components/` |
| Wire up supervision / process tree | `lib/ash_integration/application.ex`, `.../supervisor.ex`, `.../outbound/{dispatch,delivery}/supervisor.ex` |
| Emit or consume telemetry | `lib/ash_integration/telemetry.ex` (+ `guides/observability.md`) |
| Run the bundled example app | `example/` (a full host app that mounts the library) |

## Load-bearing invariants

Break one of these and something silently corrupts, leaks, or reorders. Preserve
them; if you must change one, update this list and the relevant design doc.

1. **The `Event` log is the immutable source of truth / transactional outbox.**
   `dispatched_at = NULL` means "still in the outbox." There is no separate job
   queue — relays poll the tables.
2. **Delivery is at-least-once; consumers dedup by `event-id`.** Idempotency is on
   the consumer side by design; a lost claim just gets re-claimed after its lease
   expires. A claim leases and reloads its rows **atomically** (one transaction), so a
   reload blip after the lease `UPDATE` rolls the lease + attempt bump back rather than
   orphaning a leased-but-unemitted row — see `design/outbound-architecture.md`.
3. **Per-`(connection, event_key)` ordering is a hard database invariant.** A
   partial unique index (over `state IN ('scheduled','failed')`) guarantees at most
   one in-flight/failed row per lane. Ordering is *not* something a query has to get
   right — the index enforces it. Different keys run in parallel.
4. **Coalescing is per `(subscription, event_key)`** — by default only the latest
   state per key is delivered (Kafka partition-key + log-compaction model).
5. **The signing secret never enters the Lua runtime sandbox.** It is decrypted
   live in the transport at send. Scripts are operator-authored but untrusted at
   runtime.
6. **The signature is computed fresh at send, per attempt** — recomputed over the
   exact body bytes with a send-time timestamp, so anti-replay stays honest on
   retries and secret rotation needs no reprocess.
7. **The relay is dumb; the scheduler owns all scheduling.** "One field, one fact":
   `next_attempt_at` (when), `attempts` (how many), `terminal_reason` (whether
   terminal). No field is overloaded as a sentinel for another. `:scheduled` means
   exactly "a worker is executing this right now."
8. **Two-level suspension.** Transport failures (can't reach target) suspend the
   **connection**; response rejections suspend the **subscription**. Suspended
   routes keep accumulating events — no data loss. A success resets the counters.
9. **Parking is not suspension.** A build failure (`project`/transform raised)
   *parks* a delivery; it never touches suspension counters and is recovered with
   `reprocess`, not by waiting for an endpoint. It surfaces as its own health
   dimension.
10. **Suspension health is derived and windowed**, recomputed from the delivery
    `Log` (not a hot-row `consecutive_failures` counter), with park-on-suspend to
    free capacity and a bounded probe for automatic recovery. See
    `design/connection-health.md`.

## Design docs — the *why* (read before non-trivial changes)

The `design/` docs are internal maintainers' docs: they explain *why* the code is
shaped this way. The `guides/` docs are user-facing *how-to*.

| Doc | Covers |
|-----|--------|
| `design/outbound-architecture.md` | The six load-bearing concepts (event type, producer, connection, subscription, event key, Event vs EventDelivery). **Start here.** |
| `design/delivery-retry-model.md` | Retry timing, backoff, terminal semantics, the `:failed` state, one-field-one-fact. |
| `design/connection-health.md` | Derived/windowed suspension, park-on-suspend, bounded recovery probe. |
| `design/content-suppression.md` | Content-addressed dedup, field-level subscription, `suppress_unchanged?`. |
| `design/configurable-signing.md` | Author-controlled signing schemes; the two signing invariants. |
| `guides/` | Per-transport how-tos (http/kafka/email/whatsapp), the delivery pipeline, observability, producers. |

## Conventions

- **Ash/Spark throughout.** Resources use `changes/`, `validations/`,
  `transformer.ex`, `verifier.ex` by convention — once you've seen one resource you
  can predict where things live in the others.
- **Small, single-purpose files.** A path like `delivery/changes/on_delivery_failure.ex`
  tells you its contents without opening it. Keep new files that shape.
- **Optional transports** (`brod`, `swoosh`, `gen_smtp`) are `optional: true` deps —
  guard code that touches them.

<!-- TODO(maintainer): add anything an AI/newcomer can't infer from the code —
     known gotchas, in-flight refactors, "don't touch X because Y", roadmap. -->

## Maintaining this file

**This file must stay in sync with the code — a wrong map is worse than none.**

- When you **add, move, or rename a subsystem, entry point, or transport**, update
  the relevant table row in the same change.
- When you **add, change, or remove a load-bearing invariant**, update the
  Invariants list *and* the design doc that owns it.
- When you **add a `design/` or `guides/` doc**, add it to the docs table.
- Keep entries at the **subsystem/file level, not the line level** — that's what
  keeps this doc from going stale on every commit. Don't enumerate every file in a
  directory; point at the directory and let `ls` do the rest.
- Reviewers: treat an architecture-affecting PR that leaves this file untouched as
  incomplete.
