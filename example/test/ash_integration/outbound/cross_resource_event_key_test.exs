defmodule Example.Outbound.CrossResourceEventKeyTest do
  @moduledoc """
  The marquee event-first guarantee (§3.3/§3.5/§5.2): two DIFFERENT resources
  produce the SAME event type (`stock.changed`) via two loaders, and a
  cross-resource change keys on a COARSER id than the triggering record.

  `Example.Catalog.Widget` produces `stock.changed` keyed on its own id;
  `Example.Catalog.StockItem` produces the same `stock.changed` keyed on its
  parent `widget_id`. So an item change and a widget change for the same widget
  land on ONE `(connection, event_key)` lane and — within a subscription —
  coalesce together. Mis-keying the item on its own id would put them on
  different lanes and silently fail to coalesce (the §5.3 data-loss trap). This
  is the behaviour that was previously only covered as a static catalog union.
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias Example.Catalog.{StockItem, Widget}
  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  setup do
    owner = create_user!()
    %{connection: create_connection!(owner)}
  end

  test "an item change produces stock.changed keyed on the parent widget id, not the item id",
       %{connection: dest} do
    create_subscription!(dest, "stock.changed", notify_on_every_change: true)

    widget = create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    item = create_stock_item!(%{widget_id: widget.id, quantity: 7})
    drain_dispatch!()

    [event] = events_from("stock_item")
    assert event.event_type == "stock.changed"
    assert event.event.source_resource == "stock_item"
    # Keyed on the WIDGET, not the item — the cross-resource key (§5.2).
    assert event.event_key == widget.id
    refute event.event_key == item.id
    # Subject (provenance) is still the triggering item (§3.5).
    assert event.event.source_resource_id == item.id
    assert event.event.data["widget_id"] == widget.id
  end

  test "item and widget changes for the same widget share one lane and coalesce together",
       %{connection: dest} do
    # Single subscription, default coalescing on.
    s1 = create_subscription!(dest, "stock.changed")

    widget = create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    # Item change → stock.changed keyed on the widget.
    create_stock_item!(%{widget_id: widget.id, quantity: 1})
    drain_dispatch!()

    # Widget change → stock.changed keyed on the SAME widget, same subscription.
    update_widget!(widget, %{stock: 2})
    drain_dispatch!()

    events = events_for(s1)

    # Both keyed on the widget → same (subscription, event_key) → the older
    # (item-triggered) event is coalesced away; the newest (widget) survives.
    assert Enum.map(events, & &1.event_key) |> Enum.uniq() == [widget.id]
    assert Enum.count(events, &(&1.state == :pending)) == 1
    assert Enum.count(events, &(&1.state == :cancelled)) == 1

    [pending] = Enum.filter(events, &(&1.state == :pending))
    assert pending.event.source_resource == "widget"
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "t-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end

  defp create_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "http://localhost:9999/webhook",
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_subscription!(dest, event_type, opts \\ []) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_source: "function transform(event, defaults) return event end",
        notify_on_every_change: Keyword.get(opts, :notify_on_every_change, false)
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_widget!(attrs) do
    Widget
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp update_widget!(widget, attrs) do
    widget
    |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp create_stock_item!(attrs) do
    StockItem
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # Deliveries carry the lane fields (state/event_key); the immutable Event (loaded
  # as :event) carries provenance + data.
  defp events_for(subscription) do
    EventDelivery
    |> Ash.Query.filter(subscription_id == ^subscription.id)
    |> Ash.Query.load(:event)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp events_from(source_resource) do
    EventDelivery
    |> Ash.Query.filter(event.source_resource == ^source_resource)
    |> Ash.Query.load(:event)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end
end
