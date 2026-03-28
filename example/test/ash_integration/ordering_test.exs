defmodule Example.AshIntegration.OrderingTest do
  use Example.DataCase
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers

  describe "event ordering" do
    test "second delivery for same resource snoozes when predecessor exists" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      resource_id = product.id

      # Insert two OutboundDelivery jobs for the same resource_id and integration
      {:ok, _job1} =
        AshIntegration.Workers.OutboundDelivery.new(%{
          event_id: Ash.UUIDv7.generate(),
          resource: "product",
          action: "create",
          outbound_integration_id: integration.id,
          resource_id: resource_id,
          snapshot: %{resource: "product", action: "create", data: %{id: resource_id}}
        })
        |> Oban.insert()

      {:ok, job2} =
        AshIntegration.Workers.OutboundDelivery.new(%{
          event_id: Ash.UUIDv7.generate(),
          resource: "product",
          action: "create",
          outbound_integration_id: integration.id,
          resource_id: resource_id,
          snapshot: %{resource: "product", action: "create", data: %{id: resource_id}}
        })
        |> Oban.insert()

      # The second job should snooze because job1 is a predecessor
      assert {:snooze, 30} = perform_job(AshIntegration.Workers.OutboundDelivery, job2.args)
    end

    test "delivery proceeds when no predecessors exist" do
      stub_webhook_success()
      integration = create_outbound_integration!()
      product = create_product!()

      # Directly perform a delivery job (no predecessor in the queue)
      args = %{
        "event_id" => Ash.UUIDv7.generate(),
        "resource" => "product",
        "action" => "create",
        "outbound_integration_id" => integration.id,
        "resource_id" => product.id,
        "snapshot" => %{
          "resource" => "product",
          "action" => "create",
          "data" => %{"id" => product.id}
        }
      }

      assert :ok = perform_job(AshIntegration.Workers.OutboundDelivery, args)
    end
  end
end
