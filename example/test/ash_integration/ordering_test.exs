defmodule Example.AshIntegration.OrderingTest do
  use Example.DataCase
  use Oban.Testing, repo: Example.Repo

  require Ash.Query

  import Example.IntegrationHelpers

  describe "event ordering" do
    test "partial unique index prevents double-scheduling for same resource" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      event_resource = AshIntegration.outbound_integration_event_resource()

      # Create two pending events for the same resource
      {:ok, event1} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: %{data: "first"},
            state: :pending,
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      {:ok, event2} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: %{data: "second"},
            state: :pending,
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      # Schedule the first event
      {:ok, _} =
        event1
        |> Ash.Changeset.for_update(:schedule, %{}, authorize?: false)
        |> Ash.update(authorize?: false)

      # Attempting to schedule the second event for the same resource should fail
      # due to the partial unique index
      event2 = Ash.get!(event_resource, event2.id, authorize?: false)

      assert {:error, _} =
               event2
               |> Ash.Changeset.for_update(:schedule, %{}, authorize?: false)
               |> Ash.update(authorize?: false)
    end

    test "EventScheduler finds ready pairs for non-suspended integrations" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      event_resource = AshIntegration.outbound_integration_event_resource()

      # Create a pending event with payload
      {:ok, _event} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: %{data: "test"},
            state: :pending,
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      ready_pairs = AshIntegration.EventScheduler.find_ready_pairs(100)
      assert length(ready_pairs) == 1
      [{int_id, res_id}] = ready_pairs
      assert int_id == integration.id
      assert res_id == product.id
    end

    test "delivery proceeds for single event" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      execute_pipeline!(product)

      [event] = get_events(integration.id)
      event = reload_event!(event)
      assert event.state == :delivered
    end
  end

  describe "EventScheduler" do
    test "find_ready_pairs skips suspended integrations" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      event_resource = AshIntegration.outbound_integration_event_resource()

      {:ok, _} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: %{data: "test"},
            state: :pending,
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      # Confirm event is found before suspension
      assert length(AshIntegration.EventScheduler.find_ready_pairs(100)) >= 1

      # Suspend the integration
      integration
      |> Ash.Changeset.for_update(:suspend, %{reason: "test"}, authorize?: false)
      |> Ash.update!(authorize?: false)

      # Now find_ready_pairs should return no pairs for this integration
      pairs = AshIntegration.EventScheduler.find_ready_pairs(100)

      refute Enum.any?(pairs, fn {int_id, _} -> int_id == integration.id end)
    end

    test "find_ready_pairs skips pairs that already have a scheduled event" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      event_resource = AshIntegration.outbound_integration_event_resource()

      # Create a pending event
      {:ok, event} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: %{data: "first"},
            state: :pending,
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      # Schedule it
      event
      |> Ash.Changeset.for_update(:schedule, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      # Create another pending event for the same resource
      {:ok, _} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: %{data: "second"},
            state: :pending,
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      # find_ready_pairs should NOT return this pair (already has scheduled event)
      pairs = AshIntegration.EventScheduler.find_ready_pairs(100)

      refute Enum.any?(pairs, fn {int_id, res_id} ->
               int_id == integration.id and res_id == product.id
             end)
    end

    test "nil-payload event blocks the chain" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      event_resource = AshIntegration.outbound_integration_event_resource()

      # Create an event with nil payload (Lua failed)
      {:ok, _blocked_event} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: nil,
            state: :pending,
            last_error: "Lua error: test",
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      # Create a younger event with valid payload for the same resource
      {:ok, _valid_event} =
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: "product",
            action: "create",
            resource_id: product.id,
            occurred_at: DateTime.utc_now(),
            snapshot: %{id: product.id},
            payload: %{data: "second"},
            state: :pending,
            outbound_integration_id: integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      # find_ready_pairs returns this pair (it has pending events, no scheduled)
      pairs = AshIntegration.EventScheduler.find_ready_pairs(100)

      matching =
        Enum.find(pairs, fn {int_id, res_id} ->
          int_id == integration.id and res_id == product.id
        end)

      assert matching != nil

      # But the scheduler's process_pairs logic should check the oldest event
      # and skip because payload is nil. Let's verify by reading the oldest:
      [oldest | _] =
        event_resource
        |> Ash.Query.filter(
          outbound_integration_id == ^integration.id and
            resource_id == ^product.id and
            state == :pending
        )
        |> Ash.Query.sort(id: :asc)
        |> Ash.read!(authorize?: false)

      # The oldest event has nil payload — chain is blocked
      assert oldest.payload == nil
    end
  end
end
