defmodule Example.AshIntegration.DeliveryPipelineTest do
  use Example.DataCase
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers

  describe "successful delivery" do
    test "creating a product enqueues an EventDispatcher job" do
      stub_webhook_success()
      create_outbound_integration!()

      product = create_product!()

      assert_enqueued(
        worker: AshIntegration.Workers.EventDispatcher,
        args: %{resource: "product", action: "create", resource_id: product.id}
      )
    end

    test "full pipeline: product create → dispatch → schedule → deliver → success" do
      stub_webhook_success()
      integration = create_outbound_integration!()

      product = create_product!()

      {_dispatcher_job, _all_events, _all_results} = execute_pipeline!(product)

      # Filter to events for our test integration
      [event] = get_events(integration.id)
      assert event.resource_id == product.id
      assert event.resource == "product"
      assert event.action == "create"
      assert event.payload != nil

      # Event should now be delivered
      event = reload_event!(event)
      assert event.state == :delivered

      # Verify delivery log created with success status
      [log] = get_outbound_integration_logs(integration.id)
      assert log.status == :success
      assert log.resource == "product"
      assert log.action == "create"

      # Integration should have 0 consecutive failures
      integration = reload_integration!(integration)
      assert integration.consecutive_failures == 0
    end
  end

  describe "failed delivery (5xx)" do
    test "returns error for retry and increments consecutive_failures" do
      stub_webhook_failure(500)
      integration = create_outbound_integration!()
      product = create_product!()

      execute_pipeline!(product)

      [log] = get_outbound_integration_logs(integration.id)
      assert log.status == :failed
      assert log.response_status == 500

      integration = reload_integration!(integration)
      assert integration.consecutive_failures == 1

      # Event should still be in scheduled state (Oban retries)
      [event] = get_events(integration.id)
      assert event.state == :scheduled
      assert event.attempts == 1
      assert event.last_error != nil
    end
  end

  describe "failed delivery (4xx)" do
    test "returns :ok (no retry) but records failure" do
      stub_webhook_failure(400)
      integration = create_outbound_integration!()
      product = create_product!()

      execute_pipeline!(product)

      [log] = get_outbound_integration_logs(integration.id)
      assert log.status == :failed
      assert log.response_status == 400

      integration = reload_integration!(integration)
      assert integration.consecutive_failures == 1
    end
  end

  describe "auto-suspension" do
    test "integration is auto-suspended after reaching failure threshold" do
      stub_webhook_failure(500)

      threshold = AshIntegration.auto_suspension_threshold()

      integration = create_outbound_integration!()

      # Set consecutive_failures just below the threshold
      {:ok, uuid_binary} = Ecto.UUID.dump(integration.id)

      Example.Repo.query!(
        "UPDATE outbound_integrations SET consecutive_failures = $1 WHERE id = $2",
        [threshold - 1, uuid_binary]
      )

      product = create_product!()
      execute_pipeline!(product)

      integration = reload_integration!(integration)
      assert integration.suspended == true
      assert integration.consecutive_failures >= threshold
      assert integration.suspension_reason =~ "Auto-suspended"
      # Integration should still be active (not deactivated)
      assert integration.active == true
    end
  end

  describe "Lua transform" do
    test "script returning nil creates cancelled event for audit trail" do
      stub_webhook_success()

      integration =
        create_outbound_integration!(%{
          transform_script: "-- no result set"
        })

      _product = create_product!()

      run_latest_dispatcher!()

      # Script returning nil creates a cancelled event (audit trail)
      [event] = get_events(integration.id)
      assert event.state == :cancelled
      assert event.payload == nil
      assert event.last_error == "Skipped by Lua transform"
    end

    test "broken script creates event with nil payload and last_error set" do
      stub_webhook_success()

      integration =
        create_outbound_integration!(%{
          transform_script: "result = {"
        })

      _product = create_product!()

      run_latest_dispatcher!()

      [event] = get_events(integration.id)
      assert event.state == :pending
      assert event.payload == nil
      assert event.last_error =~ "Lua error"
    end
  end

  describe "inactive integration" do
    test "inactive integration does not receive events" do
      stub_webhook_success()

      integration = create_outbound_integration!()
      Ash.update!(integration, %{}, action: :deactivate, authorize?: false)

      _product = create_product!()

      run_latest_dispatcher!()

      # No events should be created for inactive integrations
      events = get_events(integration.id)
      assert events == []
    end
  end

  describe "suspended integration" do
    test "suspended integration still creates events but doesn't schedule delivery" do
      stub_webhook_success()

      integration = create_outbound_integration!()

      # Suspend the integration
      integration
      |> Ash.Changeset.for_update(:suspend, %{reason: "Test suspension"}, authorize?: false)
      |> Ash.update!(authorize?: false)

      _product = create_product!()

      # Run dispatcher — events should be created
      run_latest_dispatcher!()

      # Events should exist with payload cached
      [event] = get_events(integration.id)
      assert event.state == :pending
      assert event.payload != nil

      # EventScheduler should skip suspended integrations
      ready_pairs = AshIntegration.EventScheduler.find_ready_pairs(100)
      assert ready_pairs == []
    end
  end
end
