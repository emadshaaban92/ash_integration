# AshIntegration

A Spark DSL extension for [Ash Framework](https://ash-hq.org) that adds outbound integration support to your Ash resources — with a built-in dashboard UI.

Declare named, versioned **event types** that your resource actions contribute to, write Lua transform scripts, and deliver payloads to external systems via HTTP, Kafka, or email. Includes event-driven delivery with at-least-once semantics, automatic retries, two-level suspension, delivery logging, and a full management UI.

## Features

- **Event-first DSL** — add `outbound_events` to any Ash resource to declare which actions contribute to which **event types** (`product.created`, `stock.changed`)
- **Subscriptions over shared connections** — a connection holds the transport, auth, and ordering domain; subscriptions hang off it, one per `(event_type, version)`
- **Multi-transport** — deliver via [HTTP](guides/http-transport.md), [Kafka](guides/kafka-transport.md), or [Email/SMTP](guides/email-transport.md)
- **Schema versioning** — pin subscriptions to specific payload versions for safe consumer upgrades
- **Lua transform scripts** — sandboxed Lua execution to reshape event data before delivery
- **Payload signing** — an explicit per-connection signing scheme (`none`/`stripe`/`custom`) across all transports: a native Stripe-style HMAC built-in, plus sandboxed custom signing scripts for novel schemes (canonical request strings, embedded body signatures)
- **Secret encryption** — credentials encrypted at rest via AshCloak
- **[Event-driven delivery](guides/delivery-pipeline.md)** — an immutable `Event` log is the source of truth (a transactional outbox); two Broadway relays claim rows directly — one fans events out, one delivers them — with no external job queue to wire
- **At-least-once semantics** — events are never lost, even if a claim is lost or a node crashes
- **Ordering & latest-state coalescing** — per-`(connection, event_key)` ordering enforced by a partial unique index (database-level correctness), with the same key driving latest-state coalescing
- **Content suppression** — opt a subscription into `suppress_unchanged` to withhold a delivery whose body matches the last delivered one (a recurring value still sends); this also gives field-level subscription for free (project the fields you care about), surfaced as a distinct `suppressed` state
- **Two-level suspension** — transport failures auto-suspend the connection, response rejections auto-suspend just the subscription (events keep accumulating, no data loss)
- **Parked health** — a broken transform parks (not suspends) its deliveries; that backlog surfaces as a derived `:healthy/:degraded/:parked` status, a dashboard stat, index/detail badges, and `[:ash_integration, :delivery, :parked]` telemetry — with an opt-in auto-suspend (default off)
- **Reprocess** — re-run Lua transforms across stuck (parked) events after fixing a script
- **Delivery logs** — full request/response logging with configurable retention
- **Built-in dashboard** — LiveView UI mirroring the model: subscriptions + connections (config), the derived event-type catalog (the contract), and the runtime drill-down events → deliveries → logs, plus transform testing

## Installation

Add `ash_integration` and its required companion `live_select` to your dependencies:

```elixir
def deps do
  [
    {:ash_integration, "~> 0.1"},
    {:live_select, "~> 1.0"}
  ]
end
```

### Optional transport dependencies

HTTP transport works out of the box. To enable the Kafka or Email transport, add its dependencies:

```elixir
# Kafka transport — requires the brod Erlang Kafka client
{:brod, "~> 4.0"},

# Email transport — SMTP over Swoosh + gen_smtp
{:swoosh, "~> 1.0"},
{:gen_smtp, "~> 1.0"}
```

The dashboard automatically shows only the transports that are available in your environment.

AshIntegration's dashboard uses [LiveSelect](https://hex.pm/packages/live_select) for the owner picker component. LiveSelect requires JavaScript hooks and Tailwind content path configuration — see the [LiveSelect installation guide](https://hexdocs.pm/live_select/readme.html#installation) for setup instructions.

### CSS Configuration

AshIntegration's dashboard UI uses [daisyUI](https://daisyui.com) classes. You must add the library to your Tailwind CSS source paths so the classes are included in your CSS output.

In your `assets/css/app.css`, add:

```css
@source "../deps/ash_integration/lib/ash_integration/web";
```

## Configuration

```elixir
# config/config.exs
config :ash_integration,
  otp_app: :my_app,
  connection_resource: MyApp.Integration.Connection,
  subscription_resource: MyApp.Integration.Subscription,
  event_resource: MyApp.Integration.Event,
  event_delivery_resource: MyApp.Integration.EventDelivery,
  delivery_log_resource: MyApp.Integration.DeliveryLog,
  source_domains: [MyApp.Catalog, MyApp.Inventory],
  domain: MyApp.Integration,
  repo: MyApp.Repo,
  actor_resource: MyApp.Accounts.User,
  vault: MyApp.Vault
```

`source_domains` are the domains scanned at boot to discover the resources that
declare event types — the derived event-type catalog the dashboard and dispatcher
read.

### Optional settings

```elixir
config :ash_integration,
  # ...required settings above
  enabled?: true,                # Run the background pipeline on this node (default: true; set false in tests)
  auto_suspension_threshold: 50, # Consecutive transport/response failures before auto-suspend (default: 50)
  parked_health_threshold: 10,   # Parked-backlog count at/above which health reads :parked vs :degraded (default: 10)
  http_max_timeout_ms: 60_000,   # Max allowed HTTP request timeout (default: 60s)
  kafka_idle_timeout_ms: 300_000,# Kafka client idle teardown (default: 5 min)
  query_log_level: false,        # Log level for internal poll/claim SQL — false silences it (default: :debug)
  # Opt-in: also auto-suspend a subscription whose PARKED backlog crosses the
  # threshold. Default OFF (parking is visible/alertable only). Distinct from the
  # failure-counter suspend — never bumps consecutive_failures; clears via reprocess
  # + unsuspend.
  parked_suspension: [enabled?: false, count_threshold: 50]
```

The dispatch relay, the delivery relay, and the scheduler poll the database on a
fixed cadence, so their claim/scan queries run several times a second whether or
not there is anything to do. At the repo's default `:debug` level that floods the
log. `query_log_level` is passed straight through as Ecto's `:log` option for those
internal queries — set it to `false` to silence them, or to any `Logger` level
(`:info`, …) to route them elsewhere. The retention sweeper's periodic `DELETE`s
honour it too (these go through Ash, so there it scopes the sweeper's `Logger` level
rather than Ecto's `:log` — `:debug`/`false` behave the same, other levels filter
the delete rather than re-route it). It does **not** touch queries that run with
real traffic (loading claimed rows, state transitions), so genuine activity still
logs at the repo default.

Per-stage tuning lives under a nested key owned by that stage; each stage
validates its own slice at boot (NimbleOptions — unknown keys / bad types fail
loudly). Every knob names an *intent*, never a Broadway internal, so the
implementation can change without breaking your config:

```elixir
config :ash_integration,
  # Dispatch stage — fan an Event out into per-subscription EventDelivery rows.
  dispatch: [
    concurrency: System.schedulers_online(), # parallel fan-out (default: scheduler count)
    poll_interval_ms: 250,       # outbox poll cadence ≈ idle latency (default: 250)
    batch_size: 100,             # events claimed + fanned out per round (default: 100)
    max_attempts: 20             # claim attempts before an Event is poison (default: 20)
  ],
  # Delivery stage — claim :scheduled EventDelivery rows and send them over their transport.
  delivery: [
    concurrency: 25,             # parallel in-flight sends — higher: delivery is I/O-bound (default: 25)
    poll_interval_ms: 250,       # outbox poll cadence ≈ idle latency (default: 250)
    batch_size: 100,             # rows claimed per round (default: 100)
    max_attempts: 20,            # claim attempts before a delivery is poison (default: 20)
    backoff_base_ms: 1_000,      # base of the durable exponential retry backoff (default: 1s)
    backoff_max_ms: 300_000      # backoff cap (default: 5 min)
  ],
  # Retention stage — autovacuum-style trim of the event-first tables.
  retention: [
    interval_ms: 60_000,         # delay between sweeps (default: 1 min)
    delete_limit: 500,           # max rows deleted per table, per pass (default: 500)
    delivery_days: 90,           # keep terminal EventDelivery + Log rows (default: 90)
    event_days: 365              # keep the immutable Event log (default: 365)
  ]
```

> The dispatch lease/reclaim window, the delivery lease (derived from
> `http_max_timeout_ms` so it always outlives the slowest send), the backoff jitter,
> and the Broadway processor/batcher wiring are **internal** — deliberately not
> knobs — so the relay implementations stay free to change. `enabled?` is the single
> on/off for the whole runtime; there are no per-stage start flags. Need
> heterogeneous placement (e.g. the relay on one node
> pool, retention on another)? Set `enabled?: false` and add the stage modules
> (`AshIntegration.Outbound.Dispatch.Supervisor`, `AshIntegration.Outbound.Retention`)
> to your own supervision tree directly.

### No queue/cron infrastructure to wire

There is **no Oban** (or any external job queue) to configure. Both halves of the
pipeline run on Broadway outbox relays started by `AshIntegration.Supervisor`,
claiming rows directly from the database:

- **Dispatch** (`AshIntegration.Outbound.Dispatch.Relay`) claims undispatched
  `Event`s (`dispatched_at IS NULL`) and fans each out into per-subscription
  `EventDelivery` rows.
- **Delivery** (`AshIntegration.Outbound.Delivery.Relay`) claims `:scheduled`
  `EventDelivery` rows (`FOR UPDATE SKIP LOCKED` + a soft lease) and sends each over
  its transport, recording success/failure with durable exponential backoff
  (`next_attempt_at`) on the row itself. A lost/crashed claim just lets the lease
  expire and another pass re-claims (idempotent) — no orphan-reconciliation job.

Cleanup of old delivery logs and delivered/cancelled events is **automatic** — no
cron to wire. The retention sweeper runs under `AshIntegration.Supervisor`
(autovacuum-style: frequent bounded passes), configured via the `retention:` block
above.

## Getting Started

### 1. Create the resources

AshIntegration ships five extensions you attach to your own resources. Each
injects all attributes, actions, relationships, and code interface automatically —
you only provide app-specific configuration (module name, table, policies).

A **Connection** holds the transport, auth, signing scheme, and ordering domain:

```elixir
defmodule MyApp.Integration.Connection do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Connection],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_connections"
    repo MyApp.Repo
  end

  policies do
    # Add your authorization rules
  end
end
```

A **Subscription** is one `(event_type, version)` under a connection, with a transform:

```elixir
defmodule MyApp.Integration.Subscription do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.Subscription],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_subscriptions"
    repo MyApp.Repo
  end

  policies do
    # Add your authorization rules
  end
end
```

An **Event** is the immutable fact — one per `(change, event_type, version)`,
captured in the source transaction (the transactional outbox):

```elixir
defmodule MyApp.Integration.Event do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Capture.Event],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_events"
    repo MyApp.Repo
  end

  policies do
    # Add your authorization rules
  end
end
```

An **EventDelivery** is the per-subscription delivery state machine — one row per
subscription an event fans out to:

```elixir
defmodule MyApp.Integration.EventDelivery do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.EventDelivery],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_event_deliveries"
    repo MyApp.Repo
  end

  policies do
    # Add your authorization rules
  end
end
```

A **DeliveryLog** records each delivery attempt:

```elixir
defmodule MyApp.Integration.DeliveryLog do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.Log],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_delivery_logs"
    repo MyApp.Repo
  end

  policies do
    # Add your authorization rules
  end
end
```

### 2. Create the domain

```elixir
defmodule MyApp.Integration do
  use Ash.Domain

  resources do
    resource MyApp.Integration.Connection
    resource MyApp.Integration.Subscription
    resource MyApp.Integration.Event
    resource MyApp.Integration.EventDelivery
    resource MyApp.Integration.DeliveryLog
  end
end
```

### 3. Create a Vault module

AshIntegration uses [AshCloak](https://hex.pm/packages/ash_cloak) to encrypt credentials. The vault **must** be configured before compilation — `compile_env!` will raise if it's missing. Create a Vault if you don't already have one:

```elixir
defmodule MyApp.Vault do
  use Cloak.Vault, otp_app: :my_app
end
```

See the [Cloak documentation](https://hexdocs.pm/cloak/readme.html) for key configuration.

### 4. Add the supervisor

Add `AshIntegration.Supervisor` to your application's supervision tree, **after your Repo and Vault** (it queries the DB and decrypts credentials at boot). It starts the runtime processes — the dispatch relay, the delivery relay, the EventScheduler, the retention sweeper, and the Kafka client manager — all gated by the single `enabled?` flag (default `true`; set `false`, e.g. in tests, to keep the whole runtime out of the tree):

```elixir
# lib/my_app/application.ex
children = [
  # ...your other children
  MyApp.Vault,
  AshIntegration.Supervisor
]
```

### 5. Generate migrations

```bash
mix ash.codegen create_integration_tables
```

### 6. Mount the dashboard

Add the dashboard routes to your router inside an authenticated `live_session`:

```elixir
# lib/my_app_web/router.ex
import AshIntegration.Web.Router

scope "/", MyAppWeb do
  pipe_through [:browser]

  live_session :admin,
    layout: {MyAppWeb.Layouts, :app},
    on_mount: [MyAppWeb.AdminAuth] do

    ash_integration_dashboard("/integrations")
  end
end
```

### 7. Run migrations

```bash
mix ecto.migrate
```

## Declaring Event Types

To make a resource's actions contribute to event types:

### 1. Implement a Producer

A producer is one module per event type. It **captures** the immutable payload
from a source change (`produce/3`, in the source transaction), derives the
**event key** (`event_key/2`, which drives ordering + coalescing), and decides who
receives the event and what it looks like for them (`project/3`). It implements
`AshIntegration.Outbound.Declare.Producer`.

```elixir
defmodule MyApp.Integration.Producers.OrderPlaced do
  use AshIntegration.Outbound.Declare.Producer

  # Capture the point-in-time payload from the change's in-memory records.
  # Batched over the {changeset, record} pairs Ash hands us; one call per bulk action.
  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_changeset, order} ->
      {order.id, %{id: order.id, reference: order.reference, status: to_string(order.status)}}
    end)
  end

  @impl true
  def example(_version), do: %{id: "order-id", reference: "ORD-001", status: "confirmed"}

  # The event key must name *what the payload is a complete snapshot of*, be stable
  # across versions, and be a non-empty string (else capture raises). Keying too
  # coarse silently drops siblings via coalescing.
  @impl true
  def event_key(_version, %{id: id}), do: id

  # Decide per subscription — authorize + route + redact in one batched pass.
  # Public is this one-liner; return {:skip, _} / {:per_subscription, …} / {:deliver, redacted} as needed.
  @impl true
  def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
end
```

See the [Producers guide](guides/producers.md) for the full callback reference, the
`produce`/`project` consistency boundary, and the event key invariant.

### 2. Add the DSL to your resource

Declare the event types this resource contributes to. An event type is the union
of every resource-level declaration that names it (same string = same logical
event), so several resources can produce one event type through the same producer.

```elixir
defmodule MyApp.Orders.Order do
  use Ash.Resource,
    extensions: [AshIntegration.Outbound.Declare.Source]

  # ...your existing resource definition

  outbound_events do
    source_resource "order"   # optional; defaults to the resource's short_name

    event "order.placed" do
      actions [:create, :confirm]
      producer MyApp.Integration.Producers.OrderPlaced
      version 1, schema: MyApp.Integration.Events.OrderPlacedV1
    end

    event "order.cancelled" do
      actions [:cancel]
      producer MyApp.Integration.Producers.OrderCancelled
      version 1
    end
  end
end
```

The `schema` is an optional module exposing `example/0` (a sample payload used to
preview transforms in the dashboard). Make sure the domain owning this resource is
listed in `:source_domains` so it's discovered at boot.

## Transports

AshIntegration supports three transport types, configured per connection. Each has its own settings, security options, and behavior:

- **[HTTP Transport](guides/http-transport.md)** — JSON payloads over HTTP with Bearer, API Key, Basic Auth, or OAuth2 client-credentials
- **[Kafka Transport](guides/kafka-transport.md)** — Kafka messages with SASL/TLS security and event-key partitioning
- **[Email Transport](guides/email-transport.md)** — email over SMTP (built on Swoosh) or Microsoft Graph app-only OAuth2, with credentials encrypted at rest

Outbound OAuth2 uses the two-legged, machine-to-machine **client-credentials** grant only (no authorization-code/consent flow, no refresh tokens). Tokens are fetched live at delivery, cached until just before expiry, and single-flighted so many concurrent deliveries share one fetch. The `client_secret` lives on the connection, encrypted at rest, and is shared by the HTTP and Email OAuth2 paths.

The HTTP and Kafka transports lead with the event type on the wire and support payload signing via the `signing` config union — `none` (default), `stripe` (native Stripe-style HMAC-SHA256, configurable header name), or `custom` (a sandboxed signing script; the secret never enters the sandbox). See the transport guides for details.

## Lua Transform Scripts

Each subscription has a Lua transform script that can customize delivery. The script exposes a `transform(event, defaults)` function: it reads the **read-only** `event` envelope and returns the (possibly modified) `defaults` table — the **pre-seeded, transport-shaped** delivery descriptor for the route. Returning `nil` skips the delivery. The no-op transform just returns `defaults` unchanged — `function transform(event, defaults) return defaults end` — and so does a subscription with no transform at all (a `nil`/blank `transform_source`, or a script that defines no `transform` function). The function only expresses overrides.

The `event` table is the canonical payload envelope (read-only input):

```
event.id          -- the event's UUIDv7
event.type        -- the event type, e.g. "order.placed"
event.version     -- the schema version
event.event_key   -- the ordering/coalescing key
event.created_at  -- ISO8601 timestamp
event.subject     -- the triggering record id
event.data        -- the produced payload
```

`defaults` is pre-seeded with everything the route would send, shaped per transport:

```
-- HTTP
defaults.method   -- "post" (default) | "put" | "patch" | "delete"
defaults.path     -- joined onto the connection's base_url
defaults.url      -- set this to a FULL absolute URL to bypass base_url + path
defaults.headers  -- the wire metadata (x-event-id, x-event-type, …), content-type,
                  --   and the connection's static headers — all overridable/removable
defaults.body     -- the body (defaults to event.data)

-- Kafka
defaults.topic, defaults.key, defaults.headers (bare, un-prefixed),
defaults.value     -- the body (defaults to event.data)
defaults.timestamp -- native record timestamp, epoch ms (defaults to event.created_at)
```

```lua
-- No-op (the default): return the pre-seeded defaults unchanged.
-- (Equivalently, leave transform_source nil/blank and define no function.)
function transform(event, defaults)
  return defaults
end

-- Customize the body
function transform(event, defaults)
  defaults.body = { order_id = event.data.id, at = event.created_at }
  return defaults
end

-- Override or REMOVE a wire header (yes, including x-event-id)
function transform(event, defaults)
  defaults.headers["x-tenant"] = event.data.tenant
  defaults.headers["x-event-id"] = nil
  return defaults
end

-- Dynamic routing
function transform(event, defaults)
  defaults.path = "/orders/" .. event.data.id        -- HTTP, joined onto base_url
  defaults.url  = "https://other.example/hook"        -- HTTP, absolute override
  return defaults
end

-- Skip: return nil → produces a cancelled event, no delivery
function transform(event, defaults)
  if event.data.status == "draft" then
    return nil
  end
  return defaults
end

-- Content suppression (when the subscription has suppress_unchanged): by default
-- the dedup hash is over the body only. Set dedup_on to compare on something else
-- (e.g. a header, or a subset of the body); it is stripped from the wire payload.
function transform(event, defaults)
  defaults.dedup_on = { stock = event.data.stock }
  return defaults
end
```

**Signature & auth.** The descriptor (body as a term, headers, routing) is resolved at dispatch and snapshotted on the event, then replayed on every retry. Two secret-derived outputs are **never** snapshotted and are injected live at delivery: `Authorization`/auth (resolved from the encrypted connection — a transform-set `authorization` header still wins), and the **signature**, which is recomputed fresh per attempt under the connection's `signing` scheme with a frozen send-time timestamp. Signing live keeps the anti-replay timestamp honest on retries and makes a rotated secret apply immediately — so reprocess is only needed to pick up an edited transform or connection/route config, not a secret rotation.

Scripts run in a sandboxed environment with no I/O, a 10KB size limit, and a 5-second timeout.

## Architecture

AshIntegration uses an **event-driven state machine** with **at-least-once** delivery semantics. The immutable `Event` log is the durable source of truth (the transactional outbox); the dispatch relay and the delivery relay are disposable execution mechanisms that claim rows directly from the database.

```
Source Resource Action
        │
        ▼
  PublishEvent Change (injected by AshIntegration.Outbound.Declare.Source)
        │  Runs IN the source transaction: resolves the event types this
        │  (resource, action) contributes and, for each *subscribed* version,
        │  runs the producer's `produce/3` to capture an immutable Event.
        │  No per-event job — the Event table IS the outbox; the relay polls it.
        ▼
  Event records (immutable facts; dispatched_at: NULL = still in the outbox)
        │
        ▼
  Dispatch relay — Broadway (AshIntegration.Outbound.Dispatch.Relay)
        │  Claims undispatched Events (FOR UPDATE SKIP LOCKED + lease)
        │  Per (event_type, version) batch: producer's `project/3`
        │    (authorize + route + redact), then the Lua transform inline →
        │    resolves + signs the delivery descriptor
        │  Creates EventDelivery records (state: pending)
        │  Stamps Event.dispatched_at (the ack); notifies the scheduler
        ▼
  EventScheduler (GenServer, adaptive: ~1s when busy, 10s idle)
        │  Skips suspended/parked lanes; the high-water gate holds a lane while
        │    an older same-event_key Event is still undispatched
        │  Promotes the oldest EventDelivery per (connection, event_key) → scheduled
        ▼
  Delivery relay — Broadway (AshIntegration.Outbound.Delivery.Relay)
        │  Claims :scheduled rows (FOR UPDATE SKIP LOCKED + soft lease;
        │    attempts bumped on the claim, next_attempt_at backoff honored)
        │  Delivers via HTTP or Kafka
        │  On success: state → delivered (slot freed), resets both failure counters
        │  On retryable failure: records error, stamps next_attempt_at backoff,
        │    stays scheduled (lane held); bumps the right suspension counter
        │  On transport failure: bumps connection counter → maybe suspend
        │  On response rejection: bumps subscription counter → maybe suspend
        ▼
  EventScheduler picks up the next EventDelivery for that (connection, event_key)
```

### Delivery States

Each `EventDelivery` (one per subscription a captured `Event` fans out to) moves
through:

| State       | Meaning                                              |
|-------------|------------------------------------------------------|
| `pending`   | Materialized with its descriptor cached, ready to schedule |
| `parked`    | Build failure (`project`/transform raised) — blocks its lane until reprocessed |
| `scheduled` | Claimed as its lane's one in-flight head; the delivery relay is sending it (or retrying it under backoff) |
| `delivered` | Successfully delivered to target system              |
| `cancelled` | Superseded by coalescing, skipped, or manually cancelled |

### Ordering & Coalescing

Events are ordered per `(connection, event_key)`. A **partial unique index** ensures at most one event per lane can be `scheduled` at a time (database-enforced). The same key drives latest-state coalescing per `(subscription, event_key)`, so by default only the latest state per key is delivered. Events on different keys run in parallel.

### Two-Level Suspension

When a target fails persistently it is **auto-suspended** (not deactivated). Transport failures (can't reach the target) suspend the **connection**, pausing all its subscriptions; response rejections suspend just that **subscription**. Suspended routes keep accumulating events — no data is lost. A successful delivery resets both counters.

### Parked Health

A broken transform/`project` **parks** its deliveries (build failure) — that is *not* a transport/response failure, so it never touches the suspension counters and is recovered with `reprocess`, not by waiting for an endpoint to come back. To keep that from being a silent blind spot, parking surfaces as its own health dimension: `parked_count` / `oldest_parked_at` aggregates on the subscription and connection, a derived `:healthy | :degraded | :parked` status (`ParkedHealth.status/1`, threshold via `parked_health_threshold`), a **"Parked"** dashboard stat, a degraded/parked badge on the index + detail pages, and `[:ash_integration, :delivery, :parked]` telemetry for alerting. By default this is visible/alertable only — set `parked_suspension: [enabled?: true, count_threshold: N]` to also auto-suspend a subscription whose parked backlog crosses `N` (a distinct, reprocess-/`unsuspend`-resumable suspension that never bumps `consecutive_failures`).

### Resilience

- **Claimer crash mid-delivery**: the delivery relay bumps `attempts` on the *claim* and stamps a soft lease, so a crashed/lost claim just lets the lease expire and another pass re-claims the still-`scheduled` row — idempotent (consumers dedup by `event-id`), no orphan-reconciliation job needed. The lease is derived from the transport timeout so it always outlives the slowest send.
- **Retryable failure**: the row stays `scheduled` (lane held) with a durable exponential backoff (`next_attempt_at`); the relay re-claims it once the backoff elapses.
- **Poison delivery**: after `delivery: [max_attempts: …]` claims (default 20) a delivery stops being retried and is left `scheduled` with its lane blocked — loud telemetry, never auto-resolved (mirrors dispatch); recover with `reprocess`/`reset_to_pending`
- **Lua script bug**: the delivery is created `parked` with `delivery: nil` and `last_error` set; reprocess after fixing the script

See the [Delivery Pipeline guide](guides/delivery-pipeline.md) for the full model, including the event key snapshot invariant and head-of-line blocking tradeoffs.

## Observability

The pipeline emits `:telemetry` for every state change relevant to a feed's health, so it can be monitored without polling Postgres. `AshIntegration.Telemetry.events/0` returns every event for a one-call `:telemetry.attach_many/4`. See the [Observability guide](guides/observability.md) for the full event reference.

## License

MIT
