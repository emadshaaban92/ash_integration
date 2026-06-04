defmodule AshIntegration.Outbound.Delivery.Changes.OnDeliverySuccess do
  @moduledoc false
  # After-action hook for the `:deliver` action.
  #
  # Writes a success `Log` and resets `consecutive_failures` on BOTH the
  # connection and the subscription — a successful delivery proves the transport
  # is healthy (connection) AND that this subscription's content is accepted
  # (subscription). All in one transaction.
  use Ash.Resource.Change

  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      create_delivery_log(event)
      reset_counter(AshIntegration.connection_resource(), event.connection_id)
      reset_counter(AshIntegration.subscription_resource(), event.subscription_id)
      {:ok, event}
    end)
  end

  defp reset_counter(resource, id) do
    table = AshPostgres.DataLayer.Info.table(resource)

    from(r in {table, resource}, where: r.id == ^id)
    |> AshIntegration.repo().update_all(set: [consecutive_failures: 0])
  end

  defp create_delivery_log(event) do
    metadata = event.delivery_metadata || %{}

    AshIntegration.delivery_log_resource()
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_type: event.event_type,
        version: event.version,
        event_key: event.event_key,
        request_payload: AshIntegration.Transport.Utils.redact_descriptor(event.delivery),
        response_status: metadata["response_status"],
        response_body:
          AshIntegration.Transport.Utils.redact_response_body(metadata["response_body"]),
        kafka_offset: metadata["kafka_offset"],
        kafka_partition: metadata["kafka_partition"],
        duration_ms: metadata["duration_ms"],
        status: :success,
        subscription_id: event.subscription_id,
        connection_id: event.connection_id,
        event_delivery_id: event.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
