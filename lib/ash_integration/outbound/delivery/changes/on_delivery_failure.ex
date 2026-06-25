defmodule AshIntegration.Outbound.Delivery.Changes.OnDeliveryFailure do
  @moduledoc false
  # After-action hook for the `:record_attempt_error` action: write the failure to
  # the delivery `Log`, classified transport vs response.
  #
  # The transport classifies each failure in `delivery_metadata["failure_class"]`:
  #
  #   * `"transport"` — couldn't reach the target (conn refused, DNS/TLS, timeout,
  #     broker down) → scopes the connection's health window.
  #   * `"response"` — the target responded with a rejection (e.g. HTTP 4xx/5xx) →
  #     scopes the subscription's health window.
  #
  # An unclassified failure defaults to `:response` (the narrower blast radius).
  # Suspension is no longer decided here — it is derived from this log by the
  # periodic recompute (`AshIntegration.Outbound.Delivery.Health`).
  #
  # A caller may force the class with `failure_class:` (e.g. `:probe` for the
  # `:record_suspended_failure` action). A forced class that is NOT a recompute scope
  # (`:transport`/`:response`) — like `:probe` — is logged for observability but is
  # invisible to the health windows, so recovery-probe failures are visible without
  # perturbing the suspend/unsuspend math.
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    forced_class = opts[:failure_class]

    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      create_delivery_log(event, forced_class)
      {:ok, event}
    end)
  end

  defp classify(metadata) do
    case metadata["failure_class"] || metadata[:failure_class] do
      v when v in ["transport", :transport] -> :transport
      _ -> :response
    end
  end

  defp create_delivery_log(event, forced_class) do
    metadata = event.delivery_metadata || %{}

    AshIntegration.delivery_log_resource()
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_type: event.event_type,
        version: event.version,
        event_key: event.event_key,
        request_payload: AshIntegration.Transport.Utils.redact_descriptor(event.delivery),
        error_message: event.last_error,
        response_status: metadata["response_status"],
        response_body:
          AshIntegration.Transport.Utils.redact_response_body(metadata["response_body"]),
        kafka_offset: metadata["kafka_offset"],
        kafka_partition: metadata["kafka_partition"],
        duration_ms: metadata["duration_ms"],
        status: :failed,
        # Persist the class so the derived-health recompute
        # (design/connection-health.md §5) can scope this row to the connection
        # (transport) or subscription (response) window. A forced class outside those
        # scopes (e.g. `:probe`) is recorded but ignored by every window.
        failure_class: forced_class || classify(metadata),
        subscription_id: event.subscription_id,
        connection_id: event.connection_id,
        event_delivery_id: event.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
