defmodule AshIntegration.Outbound.Delivery.ParkedHealth do
  @moduledoc false
  # The standing health dimension for the PARK fail-closed state.
  #
  # Park is a recoverable BUILD failure (a `project`/transform raised or returned a
  # bad shape — see `Dispatch.Specs`/`Reprocessor`). It is deliberately NOT a
  # transport/response failure: it never bumps `consecutive_failures` and never
  # suspends on its own. But a subscription whose transform is permanently broken
  # parks 100% of its deliveries while `suspended`/`consecutive_failures` stay clean
  # and every health view reads green — a blind spot. This module closes it WITHOUT
  # changing when/why a delivery parks:
  #
  #   * `status/1` derives a health tier (`:healthy | :degraded | :parked`) from the
  #     `parked_count` / `oldest_parked_at` aggregates on Subscription/Connection,
  #     for the dashboard + resource views (standing/queryable signal).
  #   * `evaluate_parked_suspend/1` — only when the opt-in parked-suspend is enabled —
  #     auto-suspends a subscription whose standing parked backlog has crossed
  #     `AshIntegration.parked_suspension_threshold/0`. The real-time
  #     `[:ash_integration, :delivery, :parked]` telemetry is emitted at the park
  #     sites themselves (`DispatchEvent.after_batch`, `Reprocessor.park!`).
  #
  # The parked-suspend is a DISTINCT suspension: it sets `suspended` (reprocess- +
  # unsuspend-resumable) without touching `consecutive_failures`, so it is never
  # conflated with the transport/response failure-counter suspend. When it fires it
  # reuses the `[:ash_integration, :subscription, :suspended]` event tagged
  # `failure_class: "parked"`, so a suspension monitor catches the opt-in halt.
  require Ash.Expr
  require Ash.Query
  require Logger

  @typedoc "Derived parked-health tier."
  @type status :: :healthy | :degraded | :parked

  @doc """
  Derive the health tier from a record carrying the loaded `:parked_count`
  aggregate:

    * `:healthy`  — no parked deliveries.
    * `:degraded` — some parked deliveries, below `parked_health_threshold/0`.
    * `:parked`   — parked backlog at/above the threshold (chronically parked).

  Requires `:parked_count` to be loaded — an unloaded aggregate raises rather than
  silently reading healthy (don't hide a missing load; cf. #14).
  """
  @spec status(map()) :: status()
  def status(record) do
    case parked_count(record) do
      count when count <= 0 -> :healthy
      count -> if count >= AshIntegration.parked_health_threshold(), do: :parked, else: :degraded
    end
  end

  @doc "True when the derived health tier is anything other than `:healthy`."
  @spec unhealthy?(map()) :: boolean()
  def unhealthy?(record), do: status(record) != :healthy

  defp parked_count(%{parked_count: count}) when is_integer(count), do: count

  defp parked_count(%{parked_count: %Ash.NotLoaded{}}) do
    raise ArgumentError,
          "parked_count aggregate not loaded — load [:parked_count] before deriving parked health"
  end

  defp parked_count(other) do
    raise ArgumentError, "expected a record with a loaded :parked_count, got: #{inspect(other)}"
  end

  @doc """
  Evaluate the opt-in parked-suspend against freshly-parked deliveries (a single
  record or a list, as returned by the dispatch bulk insert / the reprocessor).
  Non-parked rows are ignored, so callers can pass the whole bulk result.

  The `[:ash_integration, :delivery, :parked]` telemetry itself is emitted at the
  park sites (dispatch `DispatchEvent.after_batch`, `Reprocessor.park!`) — this
  function only handles the standing-backlog auto-suspend (default OFF → no-op).
  Never raises into its caller (a health side effect must not roll back a dispatch
  batch); failures are logged and swallowed.
  """
  @spec evaluate_parked_suspend(map() | [map()]) :: :ok
  def evaluate_parked_suspend(delivery_or_deliveries) do
    delivery_or_deliveries
    |> List.wrap()
    |> Enum.filter(&(Map.get(&1, :state) == :parked))
    |> maybe_parked_suspend()

    :ok
  rescue
    error ->
      Logger.warning("Parked-suspend evaluation failed (ignored): #{Exception.message(error)}")
      :ok
  end

  # ── Opt-in parked-suspend (default OFF) ───────────────────────────────────

  defp maybe_parked_suspend([]), do: :ok

  defp maybe_parked_suspend(parked) do
    if AshIntegration.parked_suspension_enabled?() do
      threshold = AshIntegration.parked_suspension_threshold()

      parked
      |> Enum.map(& &1.subscription_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.each(&maybe_suspend_subscription(&1, threshold))
    end

    :ok
  end

  # Park is subscription-shaped (the transform belongs to the subscription, and a
  # parked head blocks only that subscription's lane), so the opt-in halt acts on
  # the SUBSCRIPTION — the narrower blast radius — never the whole connection. The
  # connection's parked health stays purely visible/alertable.
  defp maybe_suspend_subscription(subscription_id, threshold) do
    if count_parked_for_subscription(subscription_id) >= threshold do
      parked_suspend(subscription_id)
    end
  end

  defp count_parked_for_subscription(subscription_id) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(subscription_id == ^subscription_id and state == :parked)
    |> Ash.count!(authorize?: false)
  end

  # Filtered (atomic) suspend on `suspended == false`, mirroring the failure-counter
  # auto-suspend (OnDeliveryFailure): exactly one concurrent crosser wins and logs;
  # the loser is a clean no-op. Crucially it does NOT bump/clear
  # `consecutive_failures` — parked-suspend is its own dimension.
  defp parked_suspend(subscription_id) do
    resource = AshIntegration.subscription_resource()
    count = count_parked_for_subscription(subscription_id)

    reason =
      "Auto-suspended: #{count} parked deliveries (broken transform/producer — reprocess to clear)"

    resource
    |> Ash.get!(subscription_id, authorize?: false)
    |> Ash.Changeset.for_update(:suspend, %{reason: reason}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(suspended == false))
    # `return_notifications?: true` (then discard): this can run inside the dispatch
    # batch transaction (the park site). Nothing consumes subscription suspension
    # notifications, and returning them keeps Ash from warning about "missed
    # notifications" — mirroring the dispatch path, which likewise discards its
    # EventDelivery notifications.
    |> Ash.update(authorize?: false, return_notifications?: true)
    |> case do
      {:ok, _record, _notifications} ->
        Logger.warning(
          "Parked-suspending subscription #{subscription_id} after #{count} parked deliveries"
        )

        emit_parked_suspended(subscription_id, count, reason)

      # A concurrent crosser already suspended it (or it was suspended for another
      # reason). Nothing to do.
      {:error, _stale} ->
        :ok
    end
  end

  # Reuse the shared `[:ash_integration, :subscription, :suspended]` event so a
  # suspension monitor catches the opt-in parked-halt too — disambiguated by
  # `failure_class: "parked"` (vs `"transport"`/`"response"`). `consecutive_failures`
  # is 0 (parked-suspend never bumps it); `parked_count` carries the magnitude that
  # crossed the threshold. Fired once per crossing (only the filtered-update winner
  # reaches here).
  defp emit_parked_suspended(subscription_id, parked_count, reason) do
    :telemetry.execute(
      [:ash_integration, :subscription, :suspended],
      %{consecutive_failures: 0, parked_count: parked_count},
      %{
        id: subscription_id,
        threshold: AshIntegration.parked_suspension_threshold(),
        failure_class: "parked",
        last_error: reason
      }
    )
  end
end
