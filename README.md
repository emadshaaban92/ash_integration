# AshIntegration

A Spark DSL extension for [Ash Framework](https://ash-hq.org) that adds outbound integration support to your Ash resources — with a built-in dashboard UI.

Declare which resource actions trigger outbound events, write Lua transform scripts, and deliver payloads to external systems via HTTP, Kafka, or gRPC. Includes event-driven delivery with at-least-once semantics, automatic retries, integration suspension, delivery logging, and a full management UI.

## Features

- **Declarative DSL** — add `outbound_integrations` to any Ash resource to declare publishable actions
- **Multi-transport** — deliver via [HTTP](guides/http-transport.md), [Kafka](guides/kafka-transport.md), or [gRPC](guides/grpc-transport.md) (experimental)
- **Schema versioning** — pin integrations to specific payload versions for safe consumer upgrades
- **Lua transform scripts** — sandboxed Lua execution to reshape event data before delivery
- **Payload signing** — HMAC-SHA256 signatures across all transports
- **Secret encryption** — credentials encrypted at rest via AshCloak
- **[Event-driven delivery](guides/delivery-pipeline.md)** — durable `OutboundIntegrationEvent` records own the full lifecycle; Oban jobs are disposable execution mechanisms
- **At-least-once semantics** — events are never lost, even if Oban jobs are discarded or nodes crash
- **Ordering guarantees** — per-resource-id ordering enforced by a partial unique index (database-level correctness)
- **Integration suspension** — auto-suspend after consecutive failures (events keep accumulating, no data loss)
- **Bulk reprocess** — re-run Lua transforms across all stuck events in one action after fixing a script
- **Delivery logs** — full request/response logging with configurable retention
- **Built-in dashboard** — LiveView UI for managing integrations, browsing events and logs, and testing transforms
- **Powered by Oban** — reliable background job processing for event dispatch and delivery

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

HTTP transport works out of the box. To enable additional transports, add their dependencies:

```elixir
# Kafka transport — requires the brod Erlang Kafka client
{:brod, "~> 4.0"}

# gRPC transport (experimental) — requires the protobuf library
# plus grpcurl and protoc executables on PATH
{:protobuf, "~> 0.13"}
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
  outbound_integration_resource: MyApp.Integration.OutboundIntegration,
  outbound_integration_log_resource: MyApp.Integration.OutboundIntegrationLog,
  outbound_integration_event_resource: MyApp.Integration.OutboundIntegrationEvent,
  domain: MyApp.Integration,
  repo: MyApp.Repo,
  actor_resource: MyApp.Accounts.User,
  vault: MyApp.Vault
```

### Optional settings

```elixir
config :ash_integration,
  # ...required settings above
  auto_suspension_threshold: 50,           # Consecutive failures before auto-suspend (default: 50)
  outbound_integration_log_retention_days: 90, # Days to keep logs and old events (default: 90)
  kafka_idle_timeout_ms: 300_000           # Kafka client idle teardown (default: 5 min)
```

### Oban queues

Add the required queues to your Oban configuration:

```elixir
config :my_app, Oban,
  queues: [
    integration_dispatch: 10,
    integration_delivery: 20,
    maintenance: 1
    # ...your other queues
  ]
```

To enable automatic cleanup of old integration logs and delivered/cancelled events, add a cron schedule:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {AshIntegration.Workers.OutboundIntegrationLogCleanup, "0 3 * * *"}
      # ...your other cron jobs
    ]}
  ]
```

## Getting Started

### 1. Create the resources

Create an `OutboundIntegration` resource. The extension injects all attributes, actions, relationships, and code interface automatically — you only need to provide app-specific configuration:

```elixir
defmodule MyApp.Integration.OutboundIntegration do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.OutboundIntegrationResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_integrations"
    repo MyApp.Repo
  end

  policies do
    # Add your authorization rules
  end
end
```

Create an `OutboundIntegrationLog` resource:

```elixir
defmodule MyApp.Integration.OutboundIntegrationLog do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.OutboundIntegrationLogResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_integration_logs"
    repo MyApp.Repo
  end

  policies do
    # Add your authorization rules
  end
end
```

Create an `OutboundIntegrationEvent` resource to track the delivery lifecycle:

```elixir
defmodule MyApp.Integration.OutboundIntegrationEvent do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.OutboundIntegrationEventResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_integration_events"
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
    resource MyApp.Integration.OutboundIntegration
    resource MyApp.Integration.OutboundIntegrationLog
    resource MyApp.Integration.OutboundIntegrationEvent
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

Add `AshIntegration.Supervisor` to your application's supervision tree. This starts runtime processes (EventScheduler, DeliveryGuardian, Kafka client manager):

```elixir
# lib/my_app/application.ex
children = [
  # ...your other children
  MyApp.Vault,
  AshIntegration.Supervisor,
  {Oban, Application.fetch_env!(:my_app, Oban)}
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

## Adding a Resource

To make a resource's actions trigger outbound integrations:

### 1. Implement a Loader

The loader fetches and transforms domain-specific data for outbound events. It returns only the data payload — the library automatically wraps it in an envelope with `id`, `resource`, `action`, `action_type`, `schema_version`, and `occurred_at`.

```elixir
defmodule MyApp.Integration.Loaders.Order do
  @behaviour AshIntegration.OutboundIntegrations.Loader

  @impl true
  def load_resource(order_id, 1 = _schema_version, actor) do
    Ash.get(MyApp.Orders.Order, order_id, actor: actor, load: [:customer, :lines])
  end

  @impl true
  def transform_event_data(order, _action, 1 = _schema_version) do
    %{
      id: order.id,
      reference: order.reference,
      status: to_string(order.status),
      customer: if(order.customer, do: %{
        name: order.customer.name,
        email: order.customer.email
      }),
      total: Decimal.to_float(order.total)
    }
  end
end
```

The loader also supports optional `sample_resource_id/2` and `build_sample_resource/2` callbacks for the dashboard's test panel preview. See the [Loaders guide](guides/loaders.md) for the full callback reference, schema versioning, and sample preview strategy.

### 2. Add the DSL to your resource

```elixir
defmodule MyApp.Orders.Order do
  use Ash.Resource,
    extensions: [AshIntegration]

  # ...your existing resource definition

  outbound_integrations do
    resource_identifier "order"
    loader MyApp.Integration.Loaders.Order
    supported_versions [1]

    outbound_action :create
    outbound_action :confirm
    outbound_action :ship
    outbound_action :cancel
  end
end
```

## Transports

AshIntegration supports three transport types. Each has its own configuration, security options, and behavior:

- **[HTTP Transport](guides/http-transport.md)** — JSON payloads over HTTP with Bearer, API Key, or Basic Auth
- **[Kafka Transport](guides/kafka-transport.md)** — Kafka messages with SASL/TLS security and partition-based ordering
- **[gRPC Transport](guides/grpc-transport.md)** *(experimental)* — Protobuf-encoded unary RPCs over HTTP/2 with TLS/mTLS support. The gRPC transport is functional but not yet at the same maturity level as HTTP and Kafka. Its interface may change in future releases.

All transports support HMAC-SHA256 payload signing via the `signing_secret` config field.

## Lua Transform Scripts

Each integration has a Lua transform script that receives the event data and can reshape it before delivery. The script has access to an `event` global table and must set a `result` global to produce output.

```lua
-- Passthrough
result = event

-- Reshape
result = {
  event_type = event.action,
  order_id = event.data.id,
  timestamp = event.occurred_at
}

-- Skip (don't set result)
if event.action == "ship" then
  result = event
end
```

Scripts run in a sandboxed environment with no I/O, a 10KB size limit, and a 5-second timeout.

## Architecture

AshIntegration uses an **event-driven state machine** with **at-least-once** delivery semantics. Events are the durable source of truth; Oban jobs are disposable execution mechanisms.

```
Source Resource Action
        │
        ▼
  PublishEvent Change (injected by AshIntegration extension)
        │  Creates EventDispatcher Oban job
        ▼
  EventDispatcher (Oban: integration_dispatch queue)
        │  Finds matching integrations (including suspended ones)
        │  Loads event data via resource Loader
        │  Runs Lua transform inline → caches payload
        │  Creates OutboundIntegrationEvent records (state: pending)
        ▼
  EventScheduler (GenServer, adaptive: ~1s when busy, 10s idle)
        │  Skips suspended integrations
        │  Finds oldest pending event per (integration, resource_id)
        │  Creates OutboundDelivery Oban job (state → scheduled)
        ▼
  OutboundDelivery (Oban: integration_delivery queue)
        │  Delivers via HTTP, Kafka, or gRPC
        │  On success: state → delivered, resets consecutive_failures
        │  On failure: records error, increments consecutive_failures
        │  Auto-suspends integration if failure threshold reached
        ▼
  EventScheduler picks up next pending event for that resource_id
```

### Event States

| State       | Meaning                                              |
|-------------|------------------------------------------------------|
| `pending`   | Created with payload cached, ready to schedule       |
| `scheduled` | Oban delivery job exists for this event              |
| `delivered` | Successfully delivered to target system              |
| `cancelled` | Manually cancelled, will not be delivered            |

### Ordering Guarantee

Events are ordered per `(integration_id, resource_id)`. A **partial unique index** ensures at most one event per resource chain can be in `scheduled` state at a time (database-enforced). Different resource IDs within the same integration run in parallel.

### Integration Suspension

When a target system fails persistently, the integration is **auto-suspended** (not deactivated). Suspended integrations continue to accumulate events in `pending` state — no data is lost. When the operator fixes the issue and un-suspends, the backlog drains in order.

### Resilience

- **Oban job lost/discarded**: DeliveryGuardian detects orphaned `scheduled` events and moves them back to `pending` for re-scheduling
- **Node crash during delivery**: Oban's Lifeline plugin rescues executing jobs; guardian catches anything missed
- **Lua script bug**: Events are created with `payload: nil` and `last_error` set; use bulk reprocess after fixing the script

## License

MIT
