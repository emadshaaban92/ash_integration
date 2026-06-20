defmodule AshIntegration.Outbound.Delivery.ParkedHealth do
  @moduledoc false
  # The standing health dimension for the PARK fail-closed state.
  #
  # Park is a recoverable BUILD failure (a `project`/transform raised or returned a
  # bad shape — see `Dispatch.Specs`/`Reprocessor`). It is deliberately NOT a
  # transport/response failure: it never feeds the derived health windows and never
  # suspends on its own. But a subscription whose transform is permanently broken
  # parks 100% of its deliveries while `suspended` stays clean (it logs no
  # transport/response failures) and every health view reads green — a blind spot.
  # This module closes it WITHOUT changing when/why a delivery parks:
  #
  #   * `status/1` derives a health tier (`:healthy | :degraded | :parked`) from the
  #     `parked_count` / `oldest_parked_at` aggregates on Subscription/Connection,
  #     for the dashboard + resource views (standing/queryable signal).
  #   * `evaluate_parked_suspend/1` — only when the opt-in parked-suspend is enabled —
  #     auto-suspends a subscription whose standing parked backlog has crossed
  #     `AshIntegration.parked_suspension_threshold/0`. It is driven POST-COMMIT
  #     (the dispatch relay after its `:dispatch` transaction, the reprocessor after
  #     its run) — never inside the dispatch transaction — so its count/update can't
  #     extend or poison that transaction. The real-time
  #     `[:ash_integration, :delivery, :parked]` telemetry is emitted at the park
  #     sites themselves (`DispatchEvent.after_batch`, `Reprocessor.park!`).
  #
  # The parked-suspend is a DISTINCT suspension: it sets `suspended` (reprocess- +
  # unsuspend-resumable) from the parked backlog, so it is never conflated with the
  # derived transport/response health suspend. When it fires it
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
  silently reading healthy (don't hide a missing load).
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
  Evaluate the opt-in parked-suspend for the subscriptions that just had deliveries
  parked, given their ids (a single id or a list; nils/dups are tolerated). Each
  subscription's STANDING parked backlog is re-counted, and any that has crossed
  `AshIntegration.parked_suspension_threshold/0` is suspended.

  Drive this POST-COMMIT — after the dispatch `:dispatch` transaction (the relay)
  or a reprocess run — never inside the dispatch transaction; the count/update here
  must not extend or poison that transaction. The
  `[:ash_integration, :delivery, :parked]` telemetry itself is emitted at the park
  sites (`DispatchEvent.after_batch`, `Reprocessor.park!`); this function only
  handles the standing-backlog auto-suspend (default OFF → no-op). Never raises
  into its caller; failures are logged and swallowed.
  """
  @spec evaluate_parked_suspend(binary() | [binary() | nil]) :: :ok
  def evaluate_parked_suspend(subscription_id_or_ids) do
    if AshIntegration.parked_suspension_enabled?() do
      threshold = AshIntegration.parked_suspension_threshold()

      subscription_id_or_ids
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.each(&maybe_suspend_subscription(&1, threshold))
    end

    :ok
  rescue
    error ->
      Logger.warning("Parked-suspend evaluation failed (ignored): #{Exception.message(error)}")
      :ok
  end

  # ── Opt-in parked-suspend (default OFF) ───────────────────────────────────

  # Park is subscription-shaped (the transform belongs to the subscription, and a
  # parked head blocks only that subscription's lane), so the opt-in halt acts on
  # the SUBSCRIPTION — the narrower blast radius — never the whole connection. The
  # connection's parked health stays purely visible/alertable.
  defp maybe_suspend_subscription(subscription_id, threshold) do
    count = count_parked_for_subscription(subscription_id)
    if count >= threshold, do: parked_suspend(subscription_id, count)
  end

  defp count_parked_for_subscription(subscription_id) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(subscription_id == ^subscription_id and state == :parked)
    |> Ash.count!(authorize?: false)
  end

  # Filtered (atomic) suspend on `suspended == false`, mirroring the derived-health
  # recompute: exactly one concurrent crosser wins and logs; the loser is a clean
  # no-op. It is its own dimension — driven by the parked backlog, not the
  # transport/response health windows.
  defp parked_suspend(subscription_id, count) do
    resource = AshIntegration.subscription_resource()

    reason =
      "Auto-suspended: #{count} parked deliveries (broken transform/producer — reprocess to clear)"

    resource
    |> Ash.get!(subscription_id, authorize?: false)
    |> Ash.Changeset.for_update(:suspend, %{reason: reason}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(suspended == false))
    # `return_notifications?: true` (then discard): nothing consumes subscription
    # suspension notifications, and returning them keeps Ash from warning about
    # "missed notifications" — mirroring the dispatch path, which likewise discards
    # its EventDelivery notifications.
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
  # `failure_class: "parked"` (vs `"transport"`/`"response"`). `parked_count`
  # carries the magnitude that crossed the threshold. Fired once per crossing (only
  # the filtered-update winner reaches here).
  defp emit_parked_suspended(subscription_id, parked_count, reason) do
    :telemetry.execute(
      [:ash_integration, :subscription, :suspended],
      %{parked_count: parked_count},
      %{
        id: subscription_id,
        threshold: AshIntegration.parked_suspension_threshold(),
        failure_class: "parked",
        last_error: reason
      }
    )
  end
end
