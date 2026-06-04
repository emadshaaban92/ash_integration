# Producers

A **producer** is the bridge between your Ash resources and an event type. There
is **one producer module per event type**, and it owns the event end to end: it
*captures* the immutable payload from a source change, derives the event's **event
key**, and decides *who* receives the event and *what it looks like* for them. You
reference one from each `event` declaration in the `outbound_events` DSL, and it
implements `AshIntegration.Outbound.Declare.Producer`.

Because an event type is the union of every resource-level declaration that names
it, one event type can be produced by several resources — all through the **same**
producer module — that pattern-match each in-memory record into the **same**
payload shape. The producer is the anti-corruption layer between heterogeneous
sources and one homogeneous event.

Version is **data, not structure**: it flows through the callbacks as an argument,
so a single module handles every version of its event type (pattern-match on the
version, or share via private helpers — there is no per-version module).

```elixir
defmodule MyApp.Outbound.OrderPlaced do
  use AshIntegration.Outbound.Declare.Producer
  # produce/3, example/1, event_key/2, project/3
end
```

## The two halves: capture and fan-out

| Callback | When | Runs |
|----------|------|------|
| `produce/3` | once per subscribed version, **in the source transaction** | captures the immutable `Event` payload |
| `event_key/2` | per produced payload | derives the ordering/coalescing key |
| `project/3` | once per `(event_type, version)` batch, **at dispatch** | authorizes + routes + redacts per subscription |
| `example/1` | preview / tests | returns a sample payload (never on the hot path) |

### `produce/3`

Captures the point-in-time payload — the input every subscription's transform
receives, and the shape a version's schema describes. It runs **synchronously in
the source transaction**, under the producer/system's own authority (there is no
per-actor authorized read here — authorization has moved to `project/3`).

```elixir
@impl true
def produce(_version, changesets_and_records, _context) do
  Map.new(changesets_and_records, fn {_changeset, record} ->
    {record.id, %{widget_id: record.id, stock: record.stock}}
  end)
end
```

- **Batched over records.** You receive the `{changeset, record}` pairs exactly as
  Ash's `after_batch` hands them, so a bulk action is **one** call. Return a
  `%{record_id => payload}` map.
- **Read the change, not just the result.** The changeset carries what the record
  can't — the before-image (`changeset.data`), arguments, and context — so a delta
  or argument-derived field is reachable here.
- **Deletes carry real data.** A destroy's `record` is the final in-transaction
  state, so a `something.deleted` payload can be more than just an id.
- **Point-in-time (T0).** The payload reflects the change *when it happened*. Keep
  here anything that must be true-as-of-T0; defer subscriber-dependent work to
  `project` (see [the consistency boundary](#the-produceproject-consistency-boundary)).
- The `context` map carries the action + actor (constant across the batch); it is
  the extension point for future capture-time data.

> **Capture-failure blast radius.** Because `produce`/`event_key` run **in the
> source transaction**, a failure here (a raise, or a failed `Event` insert) **rolls
> back the host's business action**. This is deliberate — it keeps the transactional
> outbox intact (no committed change without its event, and vice versa) — but it
> means a producer bug can block a business write. An event can opt OUT per
> declaration with `capture_isolation? true`: a `produce`/`event_key` failure for
> that event is then caught, logged, and surfaced on `[:ash_integration, :capture,
> :isolated_failure]` telemetry, and the event is **dropped** while the business
> action still commits. Use it for non-critical events where availability beats
> outbox completeness:
>
> ```elixir
> event "activity.logged" do
>   actions [:create]
>   producer MyApp.Outbound.ActivityLogged
>   version 1
>   capture_isolation? true   # a capture bug drops the event, never blocks the write
> end
> ```

### `event_key/2`

Returns the **event key** for a produced payload — the partition identity that
drives **both** delivery ordering and latest-state coalescing.

```elixir
@impl true
def event_key(_version, %{widget_id: widget_id}), do: widget_id
def event_key(_version, %{"widget_id" => widget_id}), do: widget_id
```

The event key invariant — the one rule to hold:

> **Set the event key to *what the payload is a complete snapshot of*.**

Events sharing an event key (under one connection) are delivered in occurrence
order and coalesced to the latest. So:

- Keying **coarser** than the snapshot scope (many distinct snapshots sharing a
  key — e.g. per-line-item bodies all keyed on `product_id`) makes coalescing
  silently drop sibling events: **data loss**.
- Keying **finer** simply forgoes some cross-entity ordering — safe, just weaker.

`event_key/2` takes the version so it can parse the payload, but it **must return
a value-stable key per entity**: `event_key(1, order_123)` and `event_key(2,
order_123)` must be equal, so a connection holding both a v1 and a v2 subscription
keeps both representations on one correctly-ordered lane. Keep the key on a field
that is stable across versions (`id` / `product_id`). For an aggregate body, key on
what the body snapshots:

```elixir
# A body that snapshots a product's stock should key on product_id,
# even when the change was triggered by one inventory item.
def event_key(_version, %{product_id: product_id}), do: product_id
```

**It must be a non-empty `String.t()`.** The key is the `(connection, event_key)`
lane and the `event-key` wire header. The callback is mandatory, so there is no
escape hatch: returning `nil`, a blank string, or any non-string term is a code bug
and **raises at capture** (on the source action — the change rolls back), rather
than being coerced into a garbage key. If you key on a non-string id, stringify it
here (`to_string(id)`).

### `project/3`

The single host-owned hook that decides who gets the event and what it looks like —
authorization, routing, and redaction — in one batched pass. It runs at dispatch,
once per `(event_type, version)` batch, over the candidate subscriptions (each with
its connection and owner preloaded). It is **required**.

```elixir
# Public — deliver to everyone subscribed (the one-liner)
@impl true
def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
```

Return a `%{event_id => decision}` map:

| Decision | Meaning |
|----------|---------|
| `:deliver` | deliver to every candidate, event unchanged (the public case) |
| `{:deliver, projected}` | deliver to every candidate with one shared, redacted payload |
| `{:per_subscription, %{sub_id => sub_decision}}` | decide per subscription (`:deliver` / `{:deliver, projected}` / `{:skip, reason}`) |
| `{:skip, reason}` | deliver to none — **no `EventDelivery` is created**; the immutable `Event` remains as the audit |

- **Fail-closed.** An `event_id` (or a `subscription_id` inside a
  `:per_subscription` map) missing from the result is treated as
  `{:skip, "unauthorized"}` — silence never means deliver. There is no `public?`
  flag; you always state who gets the event, even when the answer is "everyone".
- **Batched.** `events` and `subscriptions` arrive as two lists (not a cross
  product), so you can authorize the whole grid from **one** query — `Ash.can?`,
  an in-memory scope match, or a call to your own service. The library doesn't
  prescribe; it's your data.
- **Redaction is the projection.** `{:deliver, projected}` ships a narrowed payload.
  It is trusted host Elixir and runs **before** the untrusted Lua transform, so
  redaction stays on the right side of the trust boundary. It must not fabricate
  the event's identity.
- A `project` that **raises** (or returns a shape the framework can't interpret)
  is a code bug: the affected deliveries are created `parked` for an operator to
  fix and reprocess.

```elixir
# Tenant-scoped — one in-memory join over the preloaded owners
def project(events, subscriptions, _context) do
  subs_by_tenant = Enum.group_by(subscriptions, & &1.connection.owner.tenant_id)

  Map.new(events, fn event ->
    allowed = Map.get(subs_by_tenant, event.data["seller_id"], [])
    {event.id, {:per_subscription, Map.new(allowed, &{&1.id, :deliver})}}
  end)
end
```

### `example/1`

Returns a sample payload for a version, mirroring `produce/3`'s output. It is used
to preview transforms in the dashboard and in test actions — **never** on the
delivery hot path.

```elixir
@impl true
def example(_version), do: %{widget_id: "widget-id", stock: 10}
```

The dashboard's transform test runs the subscription's Lua against this sample;
nothing is delivered (no transport call, no event row, no counters touched). When a
version declares a `schema` module, its `example/0` is also available for preview.

## The produce / project consistency boundary

`produce` (T0, in the source transaction) and `project` (T1, async at dispatch)
split the work — and that split is a deliberate per-producer consistency contract:

- A field captured in `produce` is **point-in-time (T0)**.
- A field enriched in `project` reflects **dispatch time (T1)**.

The default — capture the in-memory record in `produce` — is cheap *and* correct.
Push to `project` only what is inherently dispatch-time (subscriber-dependent
scoping/redaction, which can't run at T0 because the subscription set doesn't exist
yet) or what you explicitly accept as T1. Document, per producer, which fields fall
on which side.

## Schema Versioning

A version's optional **schema** is a module exposing `example/0`, used to preview
transforms in the dashboard. Declare the supported versions on the event, and
`produce`/`event_key`/`example`/`project` all receive the `version` so one producer
serves several:

```elixir
event "order.placed" do
  actions [:create, :confirm]
  producer MyApp.Outbound.OrderPlaced

  version 1
  version 2, schema: MyApp.Events.OrderPlacedV2
end
```

```elixir
@impl true
def produce(version, changesets_and_records, _context) do
  Map.new(changesets_and_records, fn {_cs, order} -> {order.id, payload(order, version)} end)
end

defp payload(order, 1), do: %{id: order.id, customer_name: order.customer_name}

defp payload(order, 2) do
  %{id: order.id, customer: %{name: order.customer_name, email: order.customer_email}}
end
```

Each subscription is pinned to a specific `(event_type, version)`. When you add
version 2, subscriptions on version 1 keep working unchanged, and consumers migrate
at their own pace. A schema module is just a module with `example/0`:

```elixir
defmodule MyApp.Events.OrderPlacedV2 do
  def example do
    %{id: "00000000-0000-0000-0000-000000000000",
      customer: %{name: "Jane Doe", email: "jane@example.com"}}
  end
end
```

## Full Example

`stock.changed`, produced by two resources that both key on the parent widget so
their changes share one ordering lane:

```elixir
defmodule MyApp.Outbound.StockChanged do
  use AshIntegration.Outbound.Declare.Producer

  alias MyApp.Catalog.{StockItem, Widget}

  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_changeset, record} ->
      {record.id, payload(record)}
    end)
  end

  defp payload(%Widget{} = widget), do: %{widget_id: widget.id, stock: widget.stock}
  defp payload(%StockItem{} = item), do: %{widget_id: item.widget_id, quantity: item.quantity}

  @impl true
  def example(_version), do: %{widget_id: "widget-id", stock: 10}

  # Value-stable per entity across record types: both resources key on the widget
  # the payload snapshots.
  @impl true
  def event_key(_version, %{widget_id: widget_id}), do: widget_id
  def event_key(_version, %{"widget_id" => widget_id}), do: widget_id

  @impl true
  def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
end
```
