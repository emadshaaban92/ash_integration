defmodule AshIntegration.Outbound.Delivery.Changes.OnDeliverySuppressed do
  @moduledoc false
  # After-action hook for the `:suppress` action (content-addressed suppression),
  # run by the scheduler when it promotes a lane head whose body is unchanged.
  #
  # Writes a `:suppressed` `Log` so the deliveries → logs drill-down shows the
  # withheld delivery alongside real sends, and emits `[:ash_integration, :dedup,
  # :suppressed]` telemetry. Unlike `OnDeliverySuccess` it does NOT reset
  # `consecutive_failures`: a suppression never touched the transport, so it proves
  # nothing about endpoint health — resetting would mask a degrading target.
  # Suppression is neutral (it neither bumps nor resets the counters).
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, delivery ->
      create_suppressed_log(delivery)

      :telemetry.execute(
        [:ash_integration, :dedup, :suppressed],
        %{count: 1},
        %{
          subscription_id: delivery.subscription_id,
          event_type: delivery.event_type,
          event_key: delivery.event_key
        }
      )

      {:ok, delivery}
    end)
  end

  defp create_suppressed_log(delivery) do
    AshIntegration.delivery_log_resource()
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_type: delivery.event_type,
        version: delivery.version,
        event_key: delivery.event_key,
        request_payload: AshIntegration.Transport.Utils.redact_descriptor(delivery.delivery),
        error_message: delivery.last_error || "Unchanged since last delivery (suppressed)",
        status: :suppressed,
        subscription_id: delivery.subscription_id,
        connection_id: delivery.connection_id,
        event_delivery_id: delivery.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
