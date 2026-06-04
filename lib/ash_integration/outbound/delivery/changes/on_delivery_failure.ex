defmodule AshIntegration.Outbound.Delivery.Changes.OnDeliveryFailure do
  @moduledoc false
  # After-action hook for the `:record_attempt_error` action — the two-level
  # suspension classifier, all within the failing update's transaction.
  #
  # The transport classifies each failure in `delivery_metadata["failure_class"]`:
  #
  #   * `"transport"` — couldn't reach the target (conn refused, DNS/TLS, timeout,
  #     broker down) → bump the CONNECTION counter, auto-suspend the connection
  #     at threshold (pauses all its subscriptions).
  #   * `"response"` — the target responded with a rejection (e.g. HTTP 4xx/5xx)
  #     → bump THIS SUBSCRIPTION's counter, auto-suspend just it (other event
  #     types to the connection keep flowing).
  #
  # An unclassified failure defaults to `:response` — the narrower blast radius
  # (one subscription, not the whole connection). A build (transform) failure
  # never reaches here — it parked the event at dispatch with no counter.
  use Ash.Resource.Change

  require Logger
  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      create_delivery_log(event)

      case classify(event.delivery_metadata || %{}) do
        :transport ->
          bump_and_maybe_suspend(
            AshIntegration.connection_resource(),
            event.connection_id,
            "transport"
          )

        :response ->
          bump_and_maybe_suspend(
            AshIntegration.subscription_resource(),
            event.subscription_id,
            "response"
          )
      end

      {:ok, event}
    end)
  end

  defp classify(metadata) do
    case metadata["failure_class"] || metadata[:failure_class] do
      v when v in ["transport", :transport] -> :transport
      _ -> :response
    end
  end

  # Atomically increment the counter (RETURNING the post-increment value), then
  # auto-suspend if the threshold is reached and it isn't already suspended.
  defp bump_and_maybe_suspend(resource, id, kind) do
    table = AshPostgres.DataLayer.Info.table(resource)

    result =
      from(r in {table, resource},
        where: r.id == ^id,
        select: %{consecutive_failures: r.consecutive_failures, suspended: r.suspended}
      )
      |> AshIntegration.repo().update_all(inc: [consecutive_failures: 1])

    case result do
      {1, [%{consecutive_failures: new_count, suspended: suspended}]} ->
        maybe_suspend(resource, id, kind, new_count, suspended)

      # The connection/subscription was deleted between the failed delivery and
      # this hook (racing teardown). Nothing to bump or suspend — degrade rather
      # than crash the job with a match error.
      {0, _} ->
        Logger.warning(
          "#{kind_label(resource)} #{id} vanished before its #{kind} failure could be " <>
            "recorded; skipping suspension bump"
        )

        :ok
    end
  end

  defp maybe_suspend(resource, id, kind, new_count, suspended) do
    threshold = AshIntegration.auto_suspension_threshold()

    if new_count >= threshold and not suspended do
      Logger.warning(
        "Auto-suspending #{kind_label(resource)} #{id} after #{new_count} consecutive " <>
          "#{kind} failures"
      )

      resource
      |> Ash.get!(id, authorize?: false)
      |> Ash.Changeset.for_update(
        :suspend,
        %{reason: "Auto-suspended: #{new_count} consecutive #{kind} failures"},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)
    end
  end

  defp kind_label(resource) do
    if resource == AshIntegration.connection_resource(), do: "connection", else: "subscription"
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
        error_message: event.last_error,
        response_status: metadata["response_status"],
        response_body:
          AshIntegration.Transport.Utils.redact_response_body(metadata["response_body"]),
        kafka_offset: metadata["kafka_offset"],
        kafka_partition: metadata["kafka_partition"],
        duration_ms: metadata["duration_ms"],
        status: :failed,
        subscription_id: event.subscription_id,
        connection_id: event.connection_id,
        event_delivery_id: event.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
