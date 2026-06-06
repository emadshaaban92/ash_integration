defmodule Example.Outbound.ReprocessorTest do
  @moduledoc """
  Operator recovery for parked events (Task 11 / §6.3). A transform that errors
  parks the event (`:parked` state, nil payload); after the operator fixes the
  transform, `Reprocessor` re-runs it against the stored snapshot and unblocks it.
  """
  use Example.DataCase, async: false

  import Example.IntegrationHelpers, only: [create_user!: 0]

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Reprocessor
  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  setup do
    %{connection: create_connection!(create_user!())}
  end

  test "reprocessing a parked event re-runs the fixed transform and unblocks it",
       %{connection: dest} do
    sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)

    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    parked = single_event()
    assert parked.state == :parked
    assert is_nil(parked.delivery)
    assert parked.last_error =~ "Transform error"

    # Operator fixes the transform (a no-op sends the resolved defaults), then
    # reprocesses — which re-resolves AND re-signs the descriptor.
    fix_transform!(sub, "-- noop")

    assert {:ok, :pending} = Reprocessor.reprocess_event(parked)

    reloaded = single_event()
    assert reloaded.state == :pending
    assert reloaded.delivery["headers"]["x-event-type"] == "widget.updated"
    assert is_nil(reloaded.last_error)
  end

  test "reprocess feeds the transform the same envelope as dispatch (no leaked source, §7)",
       %{connection: dest} do
    # The transform echoes the whole envelope into the body, so the resolved body
    # IS the Lua input. It must be identical on dispatch and reprocess, and must
    # not carry provenance (`source`) — that stays internal.
    _sub = create_subscription!(dest, "widget.updated", "result.body = event")

    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    dispatched = single_event().delivery["body"]
    refute Map.has_key?(dispatched, "source"), "provenance must not leak into the transform (§7)"

    assert {:ok, :pending} = Reprocessor.reprocess_event(single_event())

    assert single_event().delivery["body"] == dispatched
  end

  test "the snapshot is stable until reprocess, which re-derives it (full-snapshot model)",
       %{connection: dest} do
    sub = create_subscription!(dest, "widget.updated", "-- noop")

    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    original = single_event().delivery
    refute Map.has_key?(original["headers"], "x-extra")

    # Editing the transform does NOT touch the already-dispatched event...
    fix_transform!(sub, ~s|result.headers["x-extra"] = "yes"|)
    assert single_event().delivery == original

    # ...reprocess re-runs the transform and re-snapshots the descriptor.
    assert {:ok, :pending} = Reprocessor.reprocess_event(single_event())
    assert single_event().delivery["headers"]["x-extra"] == "yes"
  end

  test "a transform that skips on reprocess cancels the event", %{connection: dest} do
    sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    fix_transform!(sub, "result = nil")

    assert {:ok, :cancelled} = Reprocessor.reprocess_event(single_event())
    assert single_event().state == :cancelled
  end

  test "a project that still raises on reprocess re-parks (not cancels), staying recoverable",
       %{connection: dest} do
    # `widget.scoped` + a widget named "raise" makes the Scoped producer's project
    # raise — dispatch parks the delivery. The transform is fine; the bug is in
    # project, and it isn't fixed yet, so reprocess must NOT terminally cancel it.
    _sub = create_subscription!(dest, "widget.scoped", "-- noop")
    create_widget!(%{name: "raise", stock: 1})
    drain_dispatch!()

    parked = single_event()
    assert parked.state == :parked
    assert parked.last_error =~ "project error"

    assert {:error, _reason} = Reprocessor.reprocess_event(parked)
    assert single_event().state == :parked, "a still-raising project must re-park, not cancel"
  end

  test "bulk reprocess returns counts and clears parked events", %{connection: dest} do
    sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
    create_widget!(%{name: "a", stock: 1})
    create_widget!(%{name: "b", stock: 1})
    drain_dispatch!()

    assert Enum.count(all_events(), &(&1.state == :parked)) == 2

    fix_transform!(sub, "-- noop")

    assert %{reprocessed: 2, failed: 0} = Reprocessor.reprocess_parked_for_connection(dest.id)
    assert Enum.all?(all_events(), &(&1.delivery != nil))
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp fix_transform!(sub, script) do
    sub
    |> Ash.Changeset.for_update(:update, %{transform_source: script}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp single_event do
    [event] = all_events()
    event
  end

  defp all_events, do: EventDelivery |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)

  defp create_subscription!(dest, event_type, transform_source) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_source: transform_source
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Plant a subscription whose transform raises at dispatch, PAST the save-time
  # smoke gate (which now rejects a script that errors on the producer's
  # example/1 through the create action). These recovery tests need a parked
  # event, so seeding bypasses validations to set up that state directly.
  defp seed_subscription!(dest, event_type, transform_source) do
    Ash.Seed.seed!(Subscription, %{
      connection_id: dest.id,
      event_type: event_type,
      version: 1,
      transform_source: transform_source,
      active: true,
      suspended: false,
      consecutive_failures: 0
    })
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

  defp create_widget!(attrs) do
    Widget
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
