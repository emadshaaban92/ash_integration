defmodule AshIntegration.Workers.OutboundDelivery do
  @moduledoc """
  Oban worker that delivers a single OutboundIntegrationEvent.

  Much simpler than the previous design: no ordering logic (handled by
  EventScheduler + partial unique index), no Lua transform (already cached
  on the event at dispatch time). Just load event, deliver via transport,
  and call the appropriate Ash action.

  No custom backoff needed — Oban's default exponential backoff works correctly
  since attempts now map 1:1 with actual delivery attempts (no snooze inflation).
  """
  use Oban.Worker,
    queue: :integration_delivery,
    max_attempts: 20

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"outbound_integration_event_id" => event_id}}) do
    event_resource = AshIntegration.outbound_integration_event_resource()

    case Ash.get(event_resource, event_id, authorize?: false) do
      {:ok, event} ->
        # Guard: if event is no longer scheduled, no-op (was cancelled or already delivered)
        if event.state != :scheduled do
          :ok
        else
          case Ash.get(
                 AshIntegration.outbound_integration_resource(),
                 event.outbound_integration_id, authorize?: false) do
            {:ok, integration} ->
              deliver(integration, event)

            {:error, _} ->
              Logger.warning(
                "Integration #{event.outbound_integration_id} not found for event #{event_id}, skipping"
              )

              :ok
          end
        end

      {:error, _} ->
        Logger.warning("Event #{event_id} not found, skipping delivery")
        :ok
    end
  end

  defp deliver(integration, event) do
    transport = AshIntegration.Transport.module_for(integration.transport_config.type)
    result = transport.deliver(integration, event.id, event.resource_id, event.payload)

    case result do
      {:ok, metadata} ->
        # :deliver transitions state, creates delivery log, AND resets
        # consecutive_failures on the integration — all within the same
        # transaction via after_action hooks.
        Ash.update!(
          Ash.Changeset.for_update(event, :deliver, %{delivery_metadata: metadata},
            authorize?: false
          ),
          authorize?: false
        )

        :ok

      {:error, metadata} ->
        # :record_attempt_error increments attempts, sets last_error,
        # creates a failure delivery log, AND increments consecutive_failures
        # on the integration (auto-suspending if threshold reached) — all
        # within the same transaction via after_action hooks.
        error_message = Map.get(metadata, :error_message, "Unknown error")

        Ash.update!(
          Ash.Changeset.for_update(
            event,
            :record_attempt_error,
            %{last_error: error_message, delivery_metadata: metadata},
            authorize?: false
          ),
          authorize?: false
        )

        if Map.get(metadata, :retryable, true) do
          {:error, error_message}
        else
          # Non-retryable errors — don't ask Oban to retry
          :ok
        end
    end
  end
end
