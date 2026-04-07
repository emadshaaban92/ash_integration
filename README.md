# AshIntegration

A Spark DSL extension for [Ash Framework](https://ash-hq.org) that adds outbound integration support to your Ash resources — with a built-in dashboard UI.

Declare which resource actions trigger outbound events, write Lua transform scripts, and deliver payloads to external systems via HTTP, Kafka, or gRPC. Includes automatic retries, failure tracking, auto-deactivation, delivery logging, and a full management UI.

## Features

- **Declarative DSL** — add `outbound_integrations` to any Ash resource to declare publishable actions
- **Multi-transport** — deliver via [HTTP](guides/http-transport.md), [Kafka](guides/kafka-transport.md), or [gRPC](guides/grpc-transport.md)
- **Schema versioning** — pin integrations to specific payload versions for safe consumer upgrades
- **Lua transform scripts** — sandboxed Lua execution to reshape event data before delivery
- **Payload signing** — HMAC-SHA256 signatures across all transports
- **Secret encryption** — credentials encrypted at rest via AshCloak
- **Failure tracking** — consecutive failure counting with configurable auto-deactivation threshold
- **Delivery ordering** — per-resource-id ordering guarantees within an integration
- **Delivery logs** — full request/response logging with configurable retention
- **Built-in dashboard** — LiveView UI for managing integrations, browsing logs, and testing transforms
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
  delivery_log_resource: MyApp.Integration.DeliveryLog,
  domain: MyApp.Integration,
  repo: MyApp.Repo,
  actor_resource: MyApp.Accounts.User,
  vault: MyApp.Vault
```

### Optional settings

```elixir
config :ash_integration,
  # ...required settings above
  auto_deactivation_threshold: 50,         # Consecutive failures before auto-deactivate (default: 50)
  delivery_log_retention_days: 90,         # Days to keep delivery logs (default: 90)
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

To enable automatic delivery log cleanup, add a cron schedule:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {AshIntegration.Workers.DeliveryLogCleanup, "0 3 * * *"}
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

Create a `DeliveryLog` resource:

```elixir
defmodule MyApp.Integration.DeliveryLog do
  use Ash.Resource,
    domain: MyApp.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.DeliveryLogResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "integration_delivery_logs"
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

Add `AshIntegration.Supervisor` to your application's supervision tree. This starts runtime processes (Kafka client manager):

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
- **[gRPC Transport](guides/grpc-transport.md)** — Protobuf-encoded unary RPCs over HTTP/2 with TLS/mTLS support

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

```
Source Resource Action
        |
        v
  PublishEvent Change (injected by AshIntegration extension)
        |
        v
  EventDispatcher (Oban: integration_dispatch queue)
    | Finds matching active integrations
    | Loads event data via resource Loader
        |
        v
  OutboundDelivery (Oban: integration_delivery queue)
    | Runs Lua transform
    | Delivers via HTTP, Kafka, or gRPC
    | Logs result to DeliveryLog
    | Tracks success/failure
        |
        v
  Auto-deactivation (after N consecutive failures)
```

## License

MIT
