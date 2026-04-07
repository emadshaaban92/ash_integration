# Loaders

Loaders are the bridge between your Ash resources and outbound integration payloads. Each resource that participates in outbound integrations needs a loader module that implements `AshIntegration.OutboundIntegrations.Loader`.

## Required Callbacks

### `load_resource/3`

Loads a resource record from the database with all the relationships needed for the event payload.

```elixir
@impl true
def load_resource(order_id, 1 = _schema_version, actor) do
  Ash.get(MyApp.Orders.Order, order_id, actor: actor, load: [:customer, :lines])
end
```

- Called with the integration owner as `actor`, so Ash policies are applied naturally
- Use the `schema_version` argument to load different relationships for different versions
- Return `{:ok, record}` or `{:error, reason}`

### `transform_event_data/3`

A pure function that transforms a loaded record into the event data map. This is the single source of truth for your payload shape.

```elixir
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
```

Important considerations:

- **Handle nil relationships** — when the actor cannot access a related resource, that relationship will be `nil`. Always guard with `if` or pattern matching.
- **Handle `%Ash.NotLoaded{}`** — unloaded relationships show up as `NotLoaded` structs, not `nil`. Check for these if your load list might vary.
- **Use the action argument** — you can return different payloads for `:create` vs `:destroy` actions.
- **Use the schema_version** — this is how you evolve payload shapes without breaking existing consumers.

The library automatically wraps your return value in an event envelope:

```elixir
%{
  id: "event-uuid",
  resource: "order",
  action: "create",
  action_type: "create",
  schema_version: 1,
  occurred_at: "2024-01-15T10:30:00Z",
  data: %{...}  # <-- your transform_event_data/3 return value
}
```

This envelope is what the Lua transform script receives as the `event` global.

## Optional Callbacks

These callbacks power the dashboard's **test panel**, which lets users preview what an integration will deliver before activating it.

### `sample_resource_id/2`

Finds a real record ID for sample previews.

```elixir
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
```

When implemented, the library loads a real record through `load_resource/3` with the integration owner as actor. This gives the most realistic preview since it uses actual data with real authorization applied.

### `build_sample_resource/2`

Builds a synthetic in-memory struct as a fallback when no real records exist.

```elixir
@impl true
def build_sample_resource(1 = _schema_version, _action) do
  %MyApp.Orders.Order{
    id: "00000000-0000-0000-0000-000000000000",
    reference: "ORD-SAMPLE-001",
    status: :confirmed,
    total: Decimal.new("99.99"),
    customer: %MyApp.Customers.Customer{
      name: "Jane Doe",
      email: "jane@example.com"
    },
    lines: []
  }
end
```

Key points:

- Populate **all relationships** with realistic data, even ones the actor might not normally see
- The library automatically filters out relationships the actor cannot access before passing the struct to `transform_event_data/3`
- This filtering uses `Ash.can/3` to check read authorization on each relationship's destination resource

## Sample Preview Strategy

The library tries to build a preview in this order:

```
1. sample_resource_id/2 implemented?
   |
   +--> YES: Found a record ID?
   |         |
   |         +--> YES: Load via load_resource/3 --> Preview with real data
   |         |
   |         +--> NO: Fall through to step 2
   |
   +--> NO: Fall through to step 2
   |
2. build_sample_resource/2 implemented?
   |
   +--> YES: Build struct --> Filter unauthorized relationships --> Preview
   |
   +--> NO: Show "no sample data" error
```

## Schema Versioning

Loaders support multiple schema versions, allowing you to evolve payload shapes over time:

```elixir
def load_resource(order_id, schema_version, actor) do
  loads = case schema_version do
    1 -> [:customer]
    2 -> [:customer, :lines, :shipping_address]
  end

  Ash.get(MyApp.Orders.Order, order_id, actor: actor, load: loads)
end

def transform_event_data(order, _action, 1 = _schema_version) do
  %{id: order.id, customer_name: order.customer.name}
end

def transform_event_data(order, _action, 2 = _schema_version) do
  %{
    id: order.id,
    customer: %{name: order.customer.name, email: order.customer.email},
    line_count: length(order.lines),
    shipping: if(order.shipping_address, do: %{city: order.shipping_address.city})
  }
end
```

Each outbound integration is pinned to a specific schema version. When you add version 2, existing integrations on version 1 continue to work unchanged. Consumers can migrate to version 2 at their own pace.

Declare supported versions in your resource's DSL:

```elixir
outbound_integrations do
  resource_identifier "order"
  loader MyApp.Integration.Loaders.Order
  supported_versions [1, 2]

  outbound_action :create
  outbound_action :ship
end
```

## Full Example

```elixir
defmodule MyApp.Integration.Loaders.Order do
  @behaviour AshIntegration.OutboundIntegrations.Loader

  @impl true
  def load_resource(order_id, schema_version, actor) do
    loads = case schema_version do
      1 -> [:customer, :lines]
    end

    Ash.get(MyApp.Orders.Order, order_id, actor: actor, load: loads)
  end

  @impl true
  def transform_event_data(order, action, 1 = _schema_version) do
    base = %{
      id: order.id,
      reference: order.reference,
      status: to_string(order.status),
      customer: if(order.customer, do: %{
        name: order.customer.name,
        email: order.customer.email
      }),
      total: Decimal.to_float(order.total)
    }

    case action do
      :destroy -> Map.take(base, [:id, :reference])
      _ -> base
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

  @impl true
  def build_sample_resource(1 = _schema_version, _action) do
    %MyApp.Orders.Order{
      id: "00000000-0000-0000-0000-000000000000",
      reference: "ORD-SAMPLE-001",
      status: :confirmed,
      total: Decimal.new("99.99"),
      customer: %MyApp.Customers.Customer{
        name: "Jane Doe",
        email: "jane@example.com"
      },
      lines: []
    }
  end
end
```
