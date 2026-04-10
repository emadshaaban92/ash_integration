defmodule AshIntegration.Changes.OnDeliveryFailure do
  @moduledoc """
  After-action hook for the `:record_attempt_error` action on OutboundIntegrationEvent.

  Creates a delivery log entry and atomically increments `consecutive_failures`
  on the parent integration. If the threshold is reached, auto-suspends the
  integration. All within the same database transaction.
  """
  use Ash.Resource.Change

  require Logger

  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      record = Ash.load!(record, :outbound_integration)
      integration = record.outbound_integration

      # Create delivery log for the failed attempt
      create_delivery_log(record, :failed)

      # Atomically increment consecutive_failures using a direct SQL update
      # to ensure the increment is atomic across concurrent workers.
      repo = AshIntegration.repo()
      integration_resource = AshIntegration.outbound_integration_resource()
      table = AshPostgres.DataLayer.Info.table(integration_resource)

      {1, [%{consecutive_failures: new_count}]} =
        from(i in {table, integration_resource},
          where: i.id == ^integration.id,
          select: %{consecutive_failures: i.consecutive_failures}
        )
        |> repo.update_all(inc: [consecutive_failures: 1])

      # Check if we should auto-suspend
      threshold = AshIntegration.auto_suspension_threshold()

      if new_count >= threshold and not integration.suspended do
        Logger.warning(
          "Auto-suspending integration #{integration.id} after #{new_count} consecutive failures"
        )

        integration
        |> Ash.Changeset.for_update(
          :suspend,
          %{reason: "Auto-suspended: #{new_count} consecutive delivery failures"},
          authorize?: false
        )
        |> Ash.update(authorize?: false)
      end

      {:ok, record}
    end)
  end

  defp create_delivery_log(event, status) do
    log_resource = AshIntegration.outbound_integration_log_resource()
    metadata = event.delivery_metadata || %{}

    log_resource
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_id: event.id,
        resource: event.resource,
        action: event.action,
        resource_id: event.resource_id,
        request_payload: event.payload,
        error_message: event.last_error,
        response_status: metadata["response_status"],
        response_body: metadata["response_body"],
        kafka_offset: metadata["kafka_offset"],
        kafka_partition: metadata["kafka_partition"],
        status: status,
        outbound_integration_id: event.outbound_integration_id,
        outbound_integration_event_id: event.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
