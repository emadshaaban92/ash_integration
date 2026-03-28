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

    test "full pipeline: product create → dispatch → deliver → success log" do
      stub_webhook_success()
      integration = create_outbound_integration!()

      product = create_product!()

      {_dispatcher_job, [delivery_job], [:ok]} = execute_pipeline!(product)

      assert delivery_job.args["outbound_integration_id"] == integration.id
      assert delivery_job.args["resource_id"] == product.id

      # Verify delivery log created with success status
      [log] = get_delivery_logs(integration.id)
      assert log.status == :success
      assert log.resource == "product"
      assert log.action == "create"
      assert log.resource_id == product.id

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

      {_, _, [result]} = execute_pipeline!(product)
      assert {:error, _} = result

      [log] = get_delivery_logs(integration.id)
      assert log.status == :failed
      assert log.response_status == 500

      integration = reload_integration!(integration)
      assert integration.consecutive_failures == 1
    end
  end

  describe "failed delivery (4xx)" do
    test "returns :ok (no retry) but records failure" do
      stub_webhook_failure(400)
      integration = create_outbound_integration!()
      product = create_product!()

      {_, _, [:ok]} = execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :failed
      assert log.response_status == 400

      integration = reload_integration!(integration)
      assert integration.consecutive_failures == 1
    end
  end

  describe "auto-deactivation" do
    test "integration is deactivated after reaching failure threshold" do
      stub_webhook_failure(500)

      threshold = AshIntegration.auto_deactivation_threshold()

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
      assert integration.active == false
      assert integration.consecutive_failures >= threshold
    end
  end

  describe "Lua transform" do
    test "script returning nil skips delivery" do
      stub_webhook_success()

      integration =
        create_outbound_integration!(%{
          transform_script: "-- no result set"
        })

      product = create_product!()
      {_, _, [:ok]} = execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :skipped
    end

    test "broken script records failure" do
      stub_webhook_success()

      integration =
        create_outbound_integration!(%{
          transform_script: "result = {"
        })

      product = create_product!()
      {_, _, [:ok]} = execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :failed
      assert log.error_message =~ "Lua error"
    end
  end

  describe "inactive integration" do
    test "inactive integration does not receive deliveries" do
      stub_webhook_success()

      integration = create_outbound_integration!()
      Ash.update!(integration, %{}, action: :deactivate, authorize?: false)

      _product = create_product!()

      [dispatcher_job] = all_enqueued(worker: AshIntegration.Workers.EventDispatcher)
      :ok = perform_job(AshIntegration.Workers.EventDispatcher, dispatcher_job.args)

      # No delivery jobs should be enqueued for inactive integrations
      delivery_jobs =
        Oban.Job
        |> Ecto.Query.where(worker: "AshIntegration.Workers.OutboundDelivery")
        |> Ecto.Query.where([j], j.state == "available")
        |> Example.Repo.all()

      assert delivery_jobs == []
    end
  end
end
