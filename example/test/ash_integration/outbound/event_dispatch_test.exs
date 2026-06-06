defmodule Example.Outbound.EventDispatchTest do
  @moduledoc """
  End-to-end tests for the event-first dispatcher (Task 3): a source change fans
  out via the registry into one Event per matching subscription, with the loader
  building the snapshot and the per-subscription transform caching the body.

  The headline case is the shared-event-key behaviour: a single `Widget` update
  contributes to two event types (`widget.updated` + `stock.changed`) via one
  loader keyed on the widget id, so both events land on the SAME
  `(connection, event_key)` ordering lane yet must NOT coalesce each other
  (coalescing is per `(subscription, event_key)`). The one-in-flight enforcement
  itself is the scheduler's job (Task 4); here we prove the precondition —
  same lane, distinct subscriptions, both deliverable.
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Scheduler
  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  setup do
    owner = create_user!()
    %{connection: create_connection!(owner)}
  end

  test "a single change fans out to every matching subscription, sharing one event key",
       %{connection: dest} do
    s1 = create_subscription!(dest, "widget.updated")
    s2 = create_subscription!(dest, "stock.changed")

    widget = create_widget!(%{name: "w", stock: 1})
    # create fires widget.updated only (stock.changed is :update-only)
    drain_dispatch!()

    update_widget!(widget, %{stock: 2})
    drain_dispatch!()

    pending = Enum.filter(all_events(), &(&1.state == :pending))

    # One deliverable event per subscription...
    assert length(pending) == 2
    assert pending |> Enum.map(& &1.subscription_id) |> Enum.sort() == Enum.sort([s1.id, s2.id])
    # ...both on the SAME (connection, event_key) lane...
    assert pending |> Enum.map(& &1.connection_id) |> Enum.uniq() == [dest.id]
    assert pending |> Enum.map(& &1.event_key) |> Enum.uniq() == [widget.id]
    # ...carrying the two distinct event types (no cross-type collapse)...
    assert pending |> Enum.map(& &1.event_type) |> Enum.sort() == [
             "stock.changed",
             "widget.updated"
           ]

    # ...and the resolved delivery descriptor carries the data as the body
    # (default no-op transform → body = event.data). Each producer snapshots the
    # widget its own way: widget.updated → %{id, …}; stock.changed → %{widget_id, …}.
    assert Enum.all?(pending, fn d ->
             body = d.delivery["body"]
             body["id"] == widget.id or body["widget_id"] == widget.id
           end)

    # The immutable Event (the fact) carries the point-in-time payload upstream;
    # the wire event-id is the Event id, shared by both deliveries of the lane.
    assert Enum.all?(
             all_facts(),
             &(&1.data["id"] == widget.id or &1.data["widget_id"] == widget.id)
           )

    assert pending |> Enum.map(& &1.event_id) |> Enum.all?(&is_binary/1)
  end

  test "coalescing collapses within a subscription but never across subscriptions",
       %{connection: dest} do
    s1 = create_subscription!(dest, "widget.updated")
    _s2 = create_subscription!(dest, "stock.changed")

    widget = create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()
    update_widget!(widget, %{stock: 2})
    drain_dispatch!()

    s1_events = events_for(s1)

    # widget.updated fired on both create and update (same key) → the older one
    # is coalesced away, leaving exactly one pending and one cancelled.
    assert Enum.count(s1_events, &(&1.state == :pending)) == 1
    assert Enum.count(s1_events, &(&1.state == :cancelled)) == 1

    # The stock.changed pending event (other subscription, same key) survived —
    # coalescing is scoped to (subscription, event_key), not the shared lane.
    assert Enum.count(all_events(), &(&1.state == :pending)) == 2
  end

  test "notify_on_every_change opts a subscription out of coalescing",
       %{connection: dest} do
    s1 = create_subscription!(dest, "widget.updated", notify_on_every_change: true)

    widget = create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()
    update_widget!(widget, %{stock: 2})
    drain_dispatch!()

    # Both the create and the update events remain pending — nothing coalesced.
    assert Enum.count(events_for(s1), &(&1.state == :pending)) == 2
  end

  test "a transform that errors parks the event (parked state, nil payload, last_error)",
       %{connection: dest} do
    s1 = create_subscription!(dest, "widget.updated", transform_source: "error('boom')")

    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    [event] = events_for(s1)
    assert event.state == :parked
    assert is_nil(event.delivery)
    # The payload lives on the immutable Event (the delivery has no snapshot).
    assert event.event.data["id"]
    assert event.last_error =~ "Transform error"
  end

  test "egress: an unresolvable base_url stays deliverable while a transform-set private URL parks",
       %{connection: _default} do
    # Build-time distinction (guard on): an unresolvable base_url stays :pending (a
    # transport case, fails at send), while a transform-set SSRF URL parks here.
    owner = create_user!()

    dead = create_connection!(owner, base_url: "https://wms.digitalhub.example.invalid/hook")
    s_dead = create_subscription!(dead, "widget.updated")

    public = create_connection!(owner, base_url: "https://1.1.1.1/hook")

    s_ssrf =
      create_subscription!(public, "widget.updated",
        transform_script: ~s|result.url = "http://169.254.169.254/latest"|
      )

    create_widget!(%{name: "w", stock: 1})
    # The guard runs in the resolver during dispatch, so enable it for the drain.
    with_egress_blocking(fn -> drain_dispatch!() end)

    # The unresolvable endpoint is deliverable (not parked), carrying a descriptor.
    [dead_delivery] = events_for(s_dead)
    assert dead_delivery.state == :pending
    assert dead_delivery.delivery["url"] == "https://wms.digitalhub.example.invalid/hook"

    # The SSRF target parks at dispatch, no descriptor.
    [ssrf_delivery] = events_for(s_ssrf)
    assert ssrf_delivery.state == :parked
    assert is_nil(ssrf_delivery.delivery)
    assert ssrf_delivery.last_error =~ "egress blocked"
  end

  test "a deactivated connection stops new events for all its subscriptions",
       %{connection: dest} do
    # `active` is the manual soft-delete (§5.6): deactivating the connection stops
    # NEW events for every subscription under it (existing ones still drain).
    create_subscription!(dest, "widget.updated")
    create_subscription!(dest, "stock.changed")

    Ash.update!(Ash.Changeset.for_update(dest, :deactivate, %{}, authorize?: false),
      authorize?: false
    )

    widget = create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()
    update_widget!(widget, %{stock: 2})
    drain_dispatch!()

    assert all_events() == []
  end

  test "a producer that returns a nil event_key raises at capture (fail-fast)",
       %{connection: dest} do
    # `Example.Outbound.BlankKey.event_key/2` returns nil. The callback is mandatory
    # and must return a non-empty string — nil is a code bug (it would collapse
    # unrelated entities onto one lane), so capture raises rather than inventing a key.
    create_subscription!(dest, "test.blank_key")

    message = assert_capture_raises(fn -> create_widget!(%{name: "w", stock: 1}) end)
    assert message =~ "must return a non-empty String.t()"
    assert message =~ "returned: nil"
    assert all_events() == []
    assert Ash.count!(Event, authorize?: false) == 0
  end

  test "a producer that returns a non-string event_key raises at capture (fail-fast)",
       %{connection: dest} do
    # `Example.Outbound.BadKey.event_key/2` returns a tuple. Coercing it would crash
    # or fabricate a garbage lane key / wire header, so capture raises (a code bug).
    create_subscription!(dest, "test.bad_key")

    message = assert_capture_raises(fn -> create_widget!(%{name: "w", stock: 1}) end)
    assert message =~ "must return a non-empty String.t()"
    # The whole source transaction rolled back — no widget, no Event.
    assert all_events() == []
    assert Ash.count!(Event, authorize?: false) == 0
  end

  test "a transform that skips creates a cancelled event for audit",
       %{connection: dest} do
    # `result = nil` → the transform skips the event.
    s1 = create_subscription!(dest, "widget.updated", transform_source: "result = nil")

    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    [event] = events_for(s1)
    assert event.state == :cancelled
    assert event.last_error == "Skipped by transform"
  end

  test "re-running dispatch for an event is idempotent — no duplicate deliveries",
       %{connection: dest} do
    # A relay claim that crashes after materializing but before stamping
    # dispatched_at re-emits when its lease expires. The unique (event_id,
    # subscription_id) identity makes the second fan-out a no-op (it must NOT
    # create a second row, nor reset the first).
    s1 = create_subscription!(dest, "widget.updated")
    create_widget!(%{name: "w", stock: 1})

    [event] = Ash.read!(Event, authorize?: false)

    run_dispatch!(event.id)
    # Advance the first delivery's state so a clobbering re-insert would be visible.
    [first] = events_for(s1)
    Scheduler.sweep()
    assert reload(first).state == :scheduled

    run_dispatch!(event.id)

    # Still exactly one delivery, and its state was not resurrected to :pending.
    assert [only] = events_for(s1)
    assert only.id == first.id
    assert only.state == :scheduled
  end

  test "a destroy carries real captured (in-txn) data, not just an id",
       %{connection: dest} do
    s1 = create_subscription!(dest, "stock.changed")

    widget = create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()
    # stock.changed triggers on :update and :destroy
    Ash.destroy!(widget, action: :destroy, authorize?: false)
    drain_dispatch!()

    # create fires widget.updated only; the destroy is the sole stock.changed event.
    [destroy_event] = events_for(s1)
    assert destroy_event.state == :pending
    assert destroy_event.event_type == "stock.changed"
    assert destroy_event.event_key == widget.id
    # Captured from the in-memory record at T0 — a destroy carries real data (§7),
    # here the StockChanged producer's %{widget_id, stock} shape.
    assert destroy_event.event.data["widget_id"] == widget.id
    assert destroy_event.event.source_action == "destroy"
  end

  test "the event id handed to the Lua transform is the id persisted on the row",
       %{connection: dest} do
    # The transform echoes the envelope id into the body, so the only way
    # `echoed_id` can equal the row id is if the id Lua saw == the id written.
    s1 =
      create_subscription!(dest, "widget.updated",
        transform_source: "result.body = { echoed_id = event.id }"
      )

    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    [event] = events_for(s1)
    # The id Lua sees is the immutable Event id (the wire event-id), not the
    # EventDelivery row id — shared across all deliveries of the event (§7/§4.3).
    assert event.delivery["body"]["echoed_id"] == event.event_id
    assert event.delivery["headers"]["x-event-id"] == to_string(event.event_id)
  end

  test "each fanned-out event gets its own id, distinct from its lane siblings",
       %{connection: dest} do
    # One change fans out to two event types on the same lane — the shared
    # change-level dispatch key must NOT become a shared row id (PK collision).
    create_subscription!(dest, "widget.updated")
    create_subscription!(dest, "stock.changed")

    widget = create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()
    update_widget!(widget, %{stock: 2})
    drain_dispatch!()

    ids = all_events() |> Enum.map(& &1.id)
    assert length(ids) == length(Enum.uniq(ids))
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

  defp create_connection!(owner, opts \\ []) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: Keyword.get(opts, :base_url, "http://localhost:9999/webhook"),
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Run `fun` with the SSRF egress guard turned ON (the suite default is off).
  defp with_egress_blocking(fun) do
    original = Application.get_env(:ash_integration, :egress)
    Application.put_env(:ash_integration, :egress, block_private?: true)

    try do
      fun.()
    after
      case original do
        nil -> Application.delete_env(:ash_integration, :egress)
        value -> Application.put_env(:ash_integration, :egress, value)
      end
    end
  end

  defp create_subscription!(dest, event_type, opts \\ []) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_source: Keyword.get(opts, :transform_source, "-- noop"),
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

  # Capture runs in the source txn (decision A), so an invalid event_key raises out
  # of the action. Return the message (whatever wrapper Ash propagates it through).
  defp assert_capture_raises(fun) do
    fun.()
    flunk("expected capture to raise on an invalid event_key")
  rescue
    e -> Exception.message(e)
  end

  defp update_widget!(widget, attrs) do
    widget
    |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)

  # The deliverable rows are now `EventDelivery` (the immutable `Event` is the
  # upstream fact, queried via `all_facts/0`).
  defp all_events do
    EventDelivery |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)
  end

  defp events_for(subscription) do
    EventDelivery
    |> Ash.Query.filter(subscription_id == ^subscription.id)
    |> Ash.Query.load(:event)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp all_facts do
    Event |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)
  end
end
