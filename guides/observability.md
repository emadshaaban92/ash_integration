# Observability

The pipeline emits `:telemetry` for every state change relevant to a feed's
health, so a host can monitor it without polling Postgres. Each event fires at
the site where the state changes: a reprocess that re-parks re-emits, and a
cancelled or suppressed delivery never emits `:delivered`.

`AshIntegration.Telemetry` is the programmatic reference;
`AshIntegration.Telemetry.events/0` returns every event for a single attach:

```elixir
:telemetry.attach_many(
  "my-app-ash-integration",
  AshIntegration.Telemetry.events(),
  &MyApp.Telemetry.handle/4,
  nil
)
```

## Events

### Capture

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:ash_integration, :capture, :isolated_failure]` | `count` | `event_type, producer` |

A producer's `capture` raised and was isolated; the business transaction
committed but nothing was written to the outbox.

### Dispatch (Event → EventDelivery)

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:ash_integration, :dispatch, :poison]` | `attempts` | `event_id, event_type, event_key` |
| `[:ash_integration, :coalesce, :events_dropped]` | `count` | `subscription_id, event_type, event_key` |

`:dispatch :poison` — an Event hit the dispatch attempt ceiling; left
undispatched, never auto-resolved. `:coalesce :events_dropped` — latest-state
coalescing collapsed superseded pending deliveries for a lane.

### Delivery (EventDelivery → transport)

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:ash_integration, :delivery, :parked]` | `count` | `event_id, event_type, event_key, subscription_id, connection_id, reason, failure_kind` |
| `[:ash_integration, :delivery, :delivered]` | `count, attempts, duration_ms` | `event_delivery_id, event_type, event_key, subscription_id, connection_id, transport` |
| `[:ash_integration, :delivery, :poison]` | `attempts` | `event_delivery_id, event_type, event_key, subscription_id, connection_id` |
| `[:ash_integration, :dedup, :suppressed]` | `count` | `subscription_id, event_type, event_key` |

- `:parked` — a build failure (never a transport failure; no counter bumped).
  `failure_kind` is `:transform` (the transform raised or returned a non-table)
  or `:project` (`project/3` raised, returned a malformed decision, or no
  producer is registered). Emitted at dispatch and on every reprocess that
  re-parks.
- `:delivered` — the target acknowledged the send. `duration_ms` is the
  source-change → ack latency (`created_at` to `delivered_at`); `transport` is
  `:http` or `:kafka`.
- `:delivery :poison` — a delivery hit the delivery attempt ceiling; left
  `:scheduled` with its lane blocked, never auto-resolved.
- `:dedup :suppressed` — a content-addressed delivery was suppressed (body
  unchanged); no transport touched.

### Suspension

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:ash_integration, :connection, :suspended]` | `consecutive_failures` | `id, threshold, failure_class, last_error` |
| `[:ash_integration, :subscription, :suspended]` | `consecutive_failures` | `id, threshold, failure_class, last_error` |
| `[:ash_integration, :connection, :unsuspended]` | `count` | `id` |
| `[:ash_integration, :subscription, :resumed]` | `count` | `id` |

A connection auto-suspends on crossing `auto_suspension_threshold` consecutive
**transport** failures (`failure_class: "transport"`); a subscription on
consecutive **response** failures (`failure_class: "response"`). `:unsuspended` /
`:resumed` fire on the inverse `unsuspend` action.

