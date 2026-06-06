defmodule AshIntegration.Outbound.Dispatch.Changes.DispatchEvent do
  @moduledoc false
  # The transactional heart of dispatch, attached to the Event `:dispatch` bulk
  # update action.
  #
  #   * `change/3` stamps `dispatched_at` (and clears any stale `dispatch_error`) on
  #     each event — persisted by the batch UPDATE.
  #   * `after_batch/3` runs INSIDE the per-batch transaction (Ash wraps
  #     `do_handle_batch` in `Ash.DataLayer.transaction`), so the deliveries it
  #     materializes — and the coalescing it does — commit **atomically** with the
  #     `dispatched_at` stamp. Either the event is dispatched AND its deliveries
  #     exist, or neither. A crashed/rolled-back batch leaves the event undispatched
  #     for the lease to re-emit; a committed event is never re-claimed
  #     (`claim/1` filters `dispatched_at IS NULL`), so no per-row idempotency check
  #     is needed.
  #
  # The delivery **specs** are precomputed OUTSIDE the transaction by
  # `AshIntegration.Outbound.Dispatch.Specs` (in the Broadway processor stage) and
  # handed in via the action's `context: %{dispatch_plan: %{event_id => [spec]}}`.
  # Business failures (project raise, transform error, bad decision) are already
  # baked into the specs as `:parked`/`:cancelled` rows — they are data here, never
  # errors — so they commit normally and never roll back the batch. Only a genuine
  # DB failure (a bang insert/update raising) aborts the transaction.
  use Ash.Resource.Change

  require Logger

  @impl true
  # `batch_change/3` (not `change/3`): Ash only invokes `after_batch/3` for changes
  # that also define a batch change, and `batch_change` serves both the single and
  # bulk paths. It stamps `dispatched_at` (+ clears `dispatch_error`) per changeset;
  # the batch UPDATE persists it, atomic with the `after_batch` materialization.
  def batch_change(changesets, _opts, _context) do
    Enum.map(changesets, fn changeset ->
      changeset
      |> Ash.Changeset.force_change_attribute(:dispatched_at, DateTime.utc_now())
      |> Ash.Changeset.force_change_attribute(:dispatch_error, nil)
    end)
  end

  @impl true
  # Runs once per batch, inside the transaction. `changesets_and_results` is
  # `[{changeset, updated_event}]`. We materialize each event's planned deliveries
  # and coalesce, then hand the events back as the batch result.
  def after_batch(changesets_and_results, _opts, context) do
    plan = dispatch_plan(context)

    Enum.map(changesets_and_results, fn {_changeset, event} ->
      plan
      |> Map.get(event.id, [])
      |> materialize_all!()

      {:ok, event}
    end)
  end

  defp dispatch_plan(%{source_context: %{dispatch_plan: plan}}) when is_map(plan), do: plan
  defp dispatch_plan(_context), do: %{}

  # Insert every spec in ONE bulk INSERT per batch (one DB round-trip instead of N),
  # then coalesce the pending ones. Coalescing runs after all inserts so a batch
  # carrying several same-key events settles to the newest.
  #
  # `notify?: false` is the direct way to say "we don't want these notifications":
  # the rows are created inside the dispatch transaction (parent `:dispatch` is also
  # `notify?: false` — see `Relay.dispatch/2`) and nothing consumes EventDelivery
  # notifications, so this skips generating them entirely — no structs allocated only
  # to be discarded, and none of the "Missed N notifications" noise that would
  # otherwise surface in host applications' own test runs.
  #
  # `sorted?: true` aligns `records` with the input order so each delivery maps back
  # to its spec's `coalesce?` flag. `stop_on_error?: true` + raising on a non-success
  # status preserves the bang contract: a genuine DB failure rolls back the whole
  # batch (leaving the event undispatched for the lease to re-emit).
  defp materialize_all!([]), do: :ok

  defp materialize_all!(specs) do
    result =
      Ash.bulk_create(
        Enum.map(specs, & &1.attrs),
        AshIntegration.event_delivery_resource(),
        :create,
        return_records?: true,
        return_errors?: true,
        sorted?: true,
        stop_on_error?: true,
        notify?: false,
        authorize?: false
      )

    case result do
      %Ash.BulkResult{status: :success, records: deliveries} ->
        coalesce_pending!(specs, deliveries)
        emit_parked(specs, deliveries)

      # The opt-in parked-suspend is NOT evaluated here: it runs post-commit in
      # the relay's `handle_batch`, so its count/update never executes inside this
      # dispatch transaction.

      %Ash.BulkResult{errors: errors} ->
        raise "EventDelivery bulk insert failed: #{inspect(errors)}"
    end
  end

  # Emit `[:ash_integration, :delivery, :parked]` from the persisted rows (after the
  # insert), not from the pure spec builder. A reprocess re-park re-emits from the
  # Reprocessor.
  defp emit_parked(specs, deliveries) do
    specs
    |> Enum.zip(deliveries)
    |> Enum.each(fn {spec, delivery} ->
      if delivery.state == :parked do
        :telemetry.execute(
          [:ash_integration, :delivery, :parked],
          %{count: 1},
          %{
            event_id: delivery.event_id,
            event_type: delivery.event_type,
            event_key: delivery.event_key,
            subscription_id: delivery.subscription_id,
            connection_id: delivery.connection_id,
            reason: delivery.last_error,
            failure_kind: Map.get(spec, :failure_kind)
          }
        )
      end
    end)
  end

  defp coalesce_pending!(specs, deliveries) do
    specs
    |> Enum.zip(deliveries)
    |> Enum.each(fn {%{coalesce?: coalesce?}, delivery} ->
      if coalesce? and delivery.state == :pending, do: coalesce_superseded!(delivery)
    end)
  end

  # ── Coalescing (latest-state) — per (subscription_id, event_key) ────────────
  # Cancel the `:pending` siblings superseded by a newer same-key delivery, keeping
  # the newest. A `:parked` sibling freezes coalescing (the lane is held for an
  # operator to fix). One atomic set-based UPDATE — there is no read→write window,
  # so it can't race the scheduler promoting a sibling to `:scheduled`. Runs inside
  # the batch transaction, so it commits with the inserts; a DB failure raises and
  # rolls the whole batch back, matching the bang inserts.
  defp coalesce_superseded!(delivery) do
    table = AshPostgres.DataLayer.Info.table(AshIntegration.event_delivery_resource())

    # Cancel every `:pending` row older than the newest `:pending`/`:parked` sibling
    # (UUIDv7 `event_id` = occurrence order), so the newest is kept. `NOT EXISTS` a
    # `:parked` sibling preserves the freeze — any parked → nothing is cancelled.
    sql = """
    UPDATE #{table} AS d
    SET state = 'cancelled', last_error = $3, updated_at = now()
    WHERE d.subscription_id = $1
      AND d.event_key = $2
      AND d.state = 'pending'
      AND d.event_id < (
        SELECT s.event_id FROM #{table} s
        WHERE s.subscription_id = $1 AND s.event_key = $2
          AND s.state IN ('pending', 'parked')
        ORDER BY s.event_id DESC
        LIMIT 1
      )
      AND NOT EXISTS (
        SELECT 1 FROM #{table} p
        WHERE p.subscription_id = $1 AND p.event_key = $2 AND p.state = 'parked'
      )
    """

    params = [
      Ecto.UUID.dump!(delivery.subscription_id),
      delivery.event_key,
      "Superseded by a newer event (coalesced)"
    ]

    case AshIntegration.repo().query(sql, params) do
      {:ok, %{num_rows: count}} when count > 0 -> report_coalesced(delivery, count)
      {:ok, _} -> :ok
      {:error, error} -> raise "coalesce UPDATE failed: #{inspect(error)}"
    end

    :ok
  end

  defp report_coalesced(delivery, count) do
    Logger.info(
      "Coalesced #{count} superseded pending delivery(ies) for subscription " <>
        "#{delivery.subscription_id} (event_key #{delivery.event_key})"
    )

    :telemetry.execute(
      [:ash_integration, :coalesce, :events_dropped],
      %{count: count},
      %{
        subscription_id: delivery.subscription_id,
        event_type: delivery.event_type,
        event_key: delivery.event_key
      }
    )
  end
end
