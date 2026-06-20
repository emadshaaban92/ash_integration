defmodule AshIntegration.Outbound.Delivery.Changes.OnDeliverySuccess do
  @moduledoc false
  # After-action hook for the `:deliver` action.
  #
  # Writes a success `Log` — the durable record the derived-health recompute
  # (`AshIntegration.Outbound.Delivery.Health`) reads to clear a connection's or
  # subscription's suspension. A success proves both transport (connection) and
  # response (subscription) health, so it counts in both scopes' windows.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      create_delivery_log(event)
      {:ok, event}
    end)
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
