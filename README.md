# AshIntegration

A Spark DSL extension for [Ash Framework](https://ash-hq.org) that adds outbound webhook/integration support to your Ash resources — with a built-in dashboard UI.

Declare which resource actions trigger outbound events, write Lua transform scripts, and deliver JSON payloads to external HTTP endpoints. Includes automatic retries, failure tracking, auto-deactivation, delivery logging, and a full management UI.

## Features

- **Declarative DSL** — add `outbound_integrations` to any Ash resource to declare publishable actions
- **Schema versioning** — pin integrations to specific payload versions for safe consumer upgrades
- **Lua transform scripts** — sandboxed Lua execution to reshape event data before delivery
- **HTTP delivery** — with configurable timeouts and auth (Bearer, API Key, Basic Auth, or none)
- **Secret encryption** — auth credentials encrypted at rest via AshCloak
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
  delivery_log_retention_days: 90          # Days to keep delivery logs (default: 90)
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

AshIntegration uses [AshCloak](https://hex.pm/packages/ash_cloak) to encrypt auth credentials. Create a Vault if you don't already have one:

```elixir
defmodule MyApp.Vault do
  use Cloak.Vault, otp_app: :my_app
end
```

See the [Cloak documentation](https://hexdocs.pm/cloak/readme.html) for key configuration.

### 4. Generate migrations

```bash
mix ash.codegen create_integration_tables
```

### 5. Mount the dashboard

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

The dashboard renders inside your app's layout — you control the navigation chrome, authentication, and authorization through your `live_session` configuration.

### 6. Run migrations

```bash
mix ecto.migrate
```

## Adding a Resource

To make a resource's actions trigger outbound integrations:

### 1. Implement a Loader

The loader fetches the domain-specific data for outbound events. It returns only the data payload — the library automatically wraps it in an envelope with `id`, `resource`, `action`, `action_type`, `schema_version`, and `occurred_at`:

```elixir
defmodule MyApp.Integration.Loaders.Order do
  @behaviour AshIntegration.OutboundIntegrations.Loader

  @impl true
  def load_event_data(order_id, _action, 1 = _schema_version, actor) do
    case Ash.get(MyApp.Orders.Order, order_id, actor: actor, load: [:customer, :lines]) do
      {:ok, order} ->
        {:ok, %{
          id: order.id,
          reference: order.reference,
          status: to_string(order.status),
          customer: %{
            name: order.customer.name,
            email: order.customer.email
          },
          total: Decimal.to_float(order.total)
        }}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def sample_resource_id(actor, _action) do
    case MyApp.Orders.Order
         |> Ash.Query.sort(id: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read(actor: actor) do
      {:ok, [order | _]} -> {:ok, order.id}
      _ -> {:error, :no_sample_resource}
    end
  end
end
```

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

The `AshIntegration` extension automatically injects a change that publishes events to Oban whenever a declared action is performed.

## Lua Transform Scripts

Each integration has a Lua transform script that receives the event data and can reshape it before delivery. The script has access to an `event` global table and must set a `result` global to produce output.

### Basic passthrough

```lua
result = event
```

### Reshape the payload

```lua
result = {
  event_type = event.action,
  order_id = event.data.id,
  customer_email = event.data.customer.email,
  timestamp = event.occurred_at
}
```

### Skip an event

If `result` is not set (or set to `nil`), the event is skipped and not delivered:

```lua
-- Only deliver "ship" events
if event.action == "ship" then
  result = event
end
```

### Security

Scripts run in a sandboxed Lua environment with:

- **No I/O** — `io`, `file`, `os.execute`, `os.exit`, `os.getenv`, `require`, `load`, `loadfile`, `dofile`, `loadstring` are all disabled
- **Size limit** — scripts are limited to 10,240 bytes
- **Timeout** — execution is killed after 5 seconds

## Architecture

```
Source Resource Action
        │
        ▼
  PublishEvent Change (injected by AshIntegration extension)
        │
        ▼
  EventDispatcher (Oban: integration_dispatch queue)
    │ Finds matching active integrations
    │ Loads event data via resource Loader
        │
        ▼
  OutboundDelivery (Oban: integration_delivery queue)
    │ Runs Lua transform
    │ Delivers HTTP request
    │ Logs result to DeliveryLog
    │ Tracks success/failure
        │
        ▼
  Auto-deactivation (after N consecutive failures)
```

## Dashboard

The built-in dashboard provides:

- **Integration list** — paginated table with status, failure count, and quick actions
- **Create/Edit** — full form with resource/action selection, schema version, HTTP config, auth, and Lua script
- **Detail view** — complete integration configuration, transport details, and recent delivery logs
- **Test panel** — run transform scripts against sample data from the database and preview input/output
- **Delivery logs** — browse all delivery attempts with request/response details, duration, and error messages

The dashboard uses [daisyUI](https://daisyui.com) for styling (included by default in Phoenix 1.8+).

## Injected Actions

The resource extensions inject these actions automatically. You can override any of them by defining an action with the same name in your resource.

### OutboundIntegration

| Action | Type | Description |
|--------|------|-------------|
| `create` | create | Create with standard fields |
| `update` | update | Update with standard fields |
| `read` | read | Default read |
| `destroy` | destroy | Default destroy |
| `by_id` | read | Get by ID |
| `index` | read | Paginated list sorted by newest first |
| `activate` | update | Set `active` to `true` |
| `deactivate` | update | Set `active` to `false` |
| `record_success` | update | Reset consecutive failures to 0 |
| `record_failure` | update | Increment consecutive failures, auto-deactivate if threshold reached |
| `auto_deactivate` | update | Deactivate with reason `:delivery_failures` |
| `test` | action | Run transform script against sample data |

### DeliveryLog

| Action | Type | Description |
|--------|------|-------------|
| `create` | create | Create with all log fields |
| `read` | read | Default read |
| `destroy` | destroy | Default destroy |
| `index` | read | Paginated list sorted by newest first |
| `for_outbound_integration` | read | Paginated logs filtered by integration ID |
| `older_than` | read | Logs older than N days (used by cleanup worker) |

## License

MIT
