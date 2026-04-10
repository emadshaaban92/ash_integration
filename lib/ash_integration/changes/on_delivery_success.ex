defmodule AshIntegration.Changes.OnDeliverySuccess do
  @moduledoc """
  After-action hook for the `:deliver` action on OutboundIntegrationEvent.

  Creates a delivery log entry and resets `consecutive_failures` on the
  parent integration — all within the same database transaction.
  """
  use Ash.Resource.Change

  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      record = Ash.load!(record, :outbound_integration)
      integration = record.outbound_integration

      # Create delivery log
      create_delivery_log(record, :success)

      # Reset consecutive failures on the integration using direct update
      # to avoid going through the old record_success action path.
      repo = AshIntegration.repo()
      integration_resource = AshIntegration.outbound_integration_resource()
      table = AshPostgres.DataLayer.Info.table(integration_resource)

      from(i in {table, integration_resource},
        where: i.id == ^integration.id
      )
      |> repo.update_all(set: [consecutive_failures: 0])

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
