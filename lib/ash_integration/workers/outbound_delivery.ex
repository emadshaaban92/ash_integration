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
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    case Ash.get(AshIntegration.outbound_integration_event_resource(), event_id,
           authorize?: false
         ) do
      {:ok, event} ->
        perform_for_event(event)

      {:error, _} ->
        Logger.warning("Event #{event_id} not found, skipping delivery")
        :ok
    end
  end

  defp perform_for_event(event) do
    case Ash.get(AshIntegration.outbound_integration_resource(), event.integration_id,
           authorize?: false
         ) do
      {:ok, integration} ->
        case delivery_decision(event, integration) do
          :deliver -> deliver(integration, event)
          :halt_suspended -> halt_suspended(event)
          :noop -> :ok
        end

      {:error, _} ->
        Logger.warning(
          "Integration #{event.integration_id} not found for event #{event.id}, skipping"
        )

        :ok
    end
  end

  @doc """
  Decides what `perform/1` should do with a loaded `(event, integration)` pair.

  Pure (no I/O) so the branching contract can be unit-tested without a database:

    * `:noop` — the event is no longer `:scheduled` (cancelled or already
      delivered), so there is nothing to do.
    * `:halt_suspended` — the integration is suspended; in-flight delivery must
      stop. The event is parked back to `:pending` and the job is cancelled.
    * `:deliver` — deliver normally.
  """
  def delivery_decision(%{state: state}, _integration) when state != :scheduled, do: :noop
  def delivery_decision(_event, %{suspended: true}), do: :halt_suspended
  def delivery_decision(_event, _integration), do: :deliver

  # Suspension must halt in-flight delivery (guides/delivery-pipeline.md: "EventScheduler
  # skips suspended integrations… delivery stops"), which the worker previously did not
  # honor for events already :scheduled. Park the event back to :pending and cancel the
  # Oban job; EventScheduler re-promotes it once the integration is unsuspended. Re-delivery
  # is at-least-once by design (consumers dedup by event ID), so reset_to_pending is safe.
  defp halt_suspended(event) do
    Ash.update!(
      Ash.Changeset.for_update(event, :reset_to_pending, %{}, authorize?: false),
      authorize?: false
    )

    {:cancel, :integration_suspended}
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
