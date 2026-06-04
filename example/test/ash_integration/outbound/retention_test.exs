defmodule Example.Outbound.RetentionTest do
  @moduledoc """
  Retention for the event-first tables. Only terminal (`delivered`/`cancelled`)
  deliveries past the retention window are reaped; recent and non-terminal (e.g.
  `pending`) ones are kept. The retention policy lives in the sweeper, not on the
  resources.
  """
  use Example.DataCase, async: false

  import Example.IntegrationHelpers, only: [create_user!: 0]

  require Ash.Query

  alias AshIntegration.Outbound.Retention
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  setup do
    dest = create_connection!(create_user!())
    sub = create_subscription!(dest)
    %{dest: dest, sub: sub}
  end

  test "reaps old terminal events, keeps recent and non-terminal", %{dest: dest, sub: sub} do
    old = DateTime.add(DateTime.utc_now(), -100, :day)

    old_delivered = seed_event(dest, sub, state: :delivered, updated_at: old)
    old_pending = seed_event(dest, sub, state: :pending, updated_at: old)
    recent_delivered = seed_event(dest, sub, state: :delivered, updated_at: DateTime.utc_now())

    assert %{event: _, event_delivery: _, delivery_log: _} = Retention.sweep()

    ids = EventDelivery |> Ash.read!(authorize?: false) |> MapSet.new(& &1.id)

    refute MapSet.member?(ids, old_delivered.id), "old delivered delivery should be reaped"
    assert MapSet.member?(ids, old_pending.id), "non-terminal delivery must be kept"
    assert MapSet.member?(ids, recent_delivered.id), "recent delivery must be kept"
  end

  test "an old Event with a remaining delivery is kept; one with no deliveries is reaped",
       %{dest: dest, sub: sub} do
    ancient = DateTime.add(DateTime.utc_now(), -400, :day)

    # An old Event whose only delivery is non-terminal: the delivery survives the
    # (shorter-window) delivery sweep, so its Event must survive the Event sweep too.
    kept = seed_old_event(ancient)

    Ash.Seed.seed!(EventDelivery, %{
      event_id: kept.id,
      event_type: "widget.updated",
      version: 1,
      event_key: "k1",
      delivery: %{"x" => 1},
      state: :pending,
      subscription_id: sub.id,
      connection_id: dest.id
    })

    # An equally-old Event with no deliveries at all → free to reap.
    orphan = seed_old_event(ancient)

    assert %{event: _, event_delivery: _, delivery_log: _} = Retention.sweep()

    event_ids = Event |> Ash.read!(authorize?: false) |> MapSet.new(& &1.id)

    assert MapSet.member?(event_ids, kept.id),
           "an old Event with a remaining (non-terminal) delivery must be kept"

    refute MapSet.member?(event_ids, orphan.id),
           "an old Event with no deliveries must be reaped"
  end

  test "a terminal/poison Event (undispatched, no deliveries) is NOT reaped by retention" do
    ancient = DateTime.add(DateTime.utc_now(), -400, :day)

    # A poison event (#60): burned through its dispatch attempts, still in the
    # outbox (dispatched_at NULL), so it never materialized any deliveries. It is
    # old enough and delivery-free, so the pre-guard filter would have reaped it —
    # which would silently unblock its lane and let a newer same-key event jump
    # ahead. The `dispatched_at IS NOT NULL` guard must keep it.
    poison = seed_old_event(ancient, dispatched_at: nil, dispatch_attempts: 20)

    # A control: an equally-old, dispatched, delivery-free event IS reaped — so the
    # test proves the guard (not just the age window) is what spares the poison row.
    dispatched_orphan = seed_old_event(ancient)

    assert %{event: _, event_delivery: _, delivery_log: _} = Retention.sweep()

    event_ids = Event |> Ash.read!(authorize?: false) |> MapSet.new(& &1.id)

    assert MapSet.member?(event_ids, poison.id),
           "an undispatched (poison) Event must survive retention so its lane stays blocked"

    refute MapSet.member?(event_ids, dispatched_orphan.id),
           "a dispatched, delivery-free Event must still be reaped"
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # A bare immutable Event with an explicit (old) created_at, so the Event-side
  # retention sweep applies. Defaults to dispatched (the normal aged-out case);
  # pass `dispatched_at: nil` to model an event still in the outbox (e.g. poison).
  defp seed_old_event(created_at, overrides \\ []) do
    Ash.Seed.seed!(
      Event,
      Map.merge(
        %{
          event_type: "widget.updated",
          version: 1,
          event_key: "k1",
          source_resource: "widget",
          source_resource_id: "r1",
          source_action: "update",
          data: %{},
          created_at: created_at,
          dispatched_at: DateTime.utc_now()
        },
        Map.new(overrides)
      )
    )
  end

  # Seed an EventDelivery (and its upstream immutable Event); `state`/`updated_at`
  # overrides drive the delivery-side retention sweep.
  defp seed_event(dest, sub, overrides) do
    event =
      Ash.Seed.seed!(Event, %{
        event_type: "widget.updated",
        version: 1,
        event_key: "k1",
        source_resource: "widget",
        source_resource_id: "r1",
        source_action: "update",
        data: %{},
        dispatched_at: DateTime.utc_now()
      })

    Ash.Seed.seed!(
      EventDelivery,
      Map.merge(
        %{
          event_id: event.id,
          event_type: "widget.updated",
          version: 1,
          event_key: "k1",
          delivery: %{"x" => 1},
          subscription_id: sub.id,
          connection_id: dest.id
        },
        Map.new(overrides)
      )
    )
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

  defp create_subscription!(dest) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: "widget.updated",
        version: 1,
        transform_script: "result = event"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
