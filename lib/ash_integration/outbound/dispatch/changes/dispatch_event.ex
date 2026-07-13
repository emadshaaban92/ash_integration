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
  #     (`claim/1` filters `dispatched_at IS NULL`). `batch_change/3` additionally
  #     pushes `dispatched_at IS NULL` onto the UPDATE itself, so even a lease-expiry
  #     race that re-claims an in-flight row can't double-dispatch it (the loser's
  #     write becomes a dropped `StaleRecord`).
  #
  # The delivery **specs** are precomputed OUTSIDE the transaction by
  # `AshIntegration.Outbound.Dispatch.Specs` (in the Broadway processor stage) and
  # handed in via the action's `context: %{dispatch_plan: %{event_id => [spec]}}`.
  # Business failures (project raise, transform error, bad decision) are already
  # baked into the specs as `:parked`/`:cancelled` rows — they are data here, never
  # errors — so they commit normally and never roll back the batch. Only a genuine
  # DB failure (a bang insert/update raising) aborts the transaction.
  use Ash.Resource.Change

  import Ash.Expr

  require Logger

  @impl true
  # `batch_change/3` (not `change/3`): Ash only invokes `after_batch/3` for changes
  # that also define a batch change, and `batch_change` serves both the single and
  # bulk paths. It stamps `dispatched_at` (+ clears `dispatch_error`) per changeset;
  # the batch UPDATE persists it, atomic with the `after_batch` materialization.
  #
  # The `is_nil(dispatched_at)` filter is a load-bearing idempotency fence, NOT
  # decoration: the dispatch lease (`@lease_seconds`, a fixed 60s node-liveness
  # backstop) can expire mid-fan-out while `Specs.specs_for_event` runs slow Lua
  # transforms sequentially per subscription, so another pass/node can re-claim the
  # SAME row and dispatch it concurrently. Pushing `AND dispatched_at IS NULL` onto
  # the UPDATE makes the loser's write match zero rows → Ash yields a `StaleRecord`
  # that the non-atomic bulk path silently drops (the row never reaches
  # `after_batch`), so there are no duplicate deliveries, no silent `dispatched_at`
  # re-stamp on skip-plan events, and no unique-constraint raise recording a
  # misleading `dispatch_error` on an event that dispatched fine.
  #
  # CAUTION: "the non-atomic bulk path silently drops a `StaleRecord`" is Ash
  # *behavior* (deps/ash update/bulk.ex ~L2803: `{:error, %StaleRecord{}} -> {:cont,
  # {:ok, results}}`), not a documented contract. If a future Ash surfaced it as an
  # error instead, a fully-stale batch would flip to `{:error, _}` → `retry_one` per
  # event → every retry also stale → the batch acked as failed though it actually
  # dispatched. The "re-claimed already-dispatched skip-plan event is not re-stamped"
  # test in `dispatch_relay_test` is keyed to this exact behavior and must NOT be
  # simplified away — it is the tripwire for that Ash change.
  def batch_change(changesets, _opts, _context) do
    Enum.map(changesets, fn changeset ->
      changeset
      |> Ash.Changeset.filter(expr(is_nil(dispatched_at)))
      |> Ash.Changeset.force_change_attribute(:dispatched_at, DateTime.utc_now())
      |> Ash.Changeset.force_change_attribute(:dispatch_error, nil)
      # Also clear any terminal bit set concurrently by the age sweep. The claim gated
      # on `dispatch_terminal_reason IS NULL`, but a stale claimer (lease expired) can
      # be mid-fan-out when the sweep takes the same row `:expired`; if this UPDATE then
      # wins the row would be BOTH dispatched AND `:expired` — a confusing
      # dashboard/telemetry artifact (harmless: `claim/1` gates on `dispatched_at`,
      # `reset_terminal` filters `is_nil(dispatched_at)`). The sweep's other end
      # (skipping lease-held rows) makes the collision rare; this closes it entirely.
      #
      # It MUST be an `atomic_update`, not `force_change_attribute`: the claimed struct
      # this changeset carries was loaded BEFORE the sweep, so its in-memory
      # `dispatch_terminal_reason` is already nil — `force_change_attribute(_, nil)`
      # would diff to a no-op (Ash drops an attribute whose data value and new value are
      # both nil) and never reach the SET. An atomic `nil` is emitted unconditionally,
      # so the UPDATE always clears whatever the sweep committed.
      |> Ash.Changeset.atomic_update(:dispatch_terminal_reason, expr(nil))
    end)
  end

  @impl true
  # Runs once per batch, inside the transaction. `changesets_and_results` is
  # `[{changeset, updated_event}]`. We flatten EVERY event's planned deliveries into
  # ONE bulk INSERT for the whole batch, then coalesce every affected lane in ONE
  # set-based UPDATE. So a Broadway batch of N events costs 1 INSERT + 1 UPDATE
  # round-trip here, not N sequential inserts plus one UPDATE per coalescing delivery.
  # Fewer round-trips ⇒ the transaction holds its `batch_size × subscriptions` row
  # locks for less wall-clock, easing contention with the scheduler. The events are
  # handed back (in input order) as the batch result.
  def after_batch(changesets_and_results, _opts, context) do
    plan = dispatch_plan(context)
    events = Enum.map(changesets_and_results, fn {_changeset, event} -> event end)

    events
    |> Enum.flat_map(&Map.get(plan, &1.id, []))
    |> materialize_batch!()

    Enum.map(events, &{:ok, &1})
  end

  defp dispatch_plan(%{source_context: %{dispatch_plan: plan}}) when is_map(plan), do: plan
  defp dispatch_plan(_context), do: %{}

  # Insert every spec across the WHOLE batch in ONE bulk INSERT, then coalesce the
  # pending ones. Coalescing runs after ALL inserts so a batch carrying several
  # same-key events settles to the newest.
  #
  # `batch_size: length(specs)` pins the insert to a single chunk: Ash's bulk_create
  # otherwise splits at its default 100-row `batch_size`, and here we want one
  # round-trip, not `ceil(rows / 100)`. Atomicity does NOT depend on this — the
  # enclosing dispatch transaction already makes the fan-out all-or-nothing — so a
  # chunked insert would still be correct; the pin is purely to collapse round-trips.
  # (Keep the `batch_size` dispatch knob modest, as its own docs advise, so the row
  # count stays well under Postgres's bind-parameter ceiling.)
  #
  # `notify?: false` is the direct way to say "we don't want these notifications":
  # the rows are created inside the dispatch transaction (parent `:dispatch` is also
  # `notify?: false` — see `Relay.dispatch/2`) and nothing consumes EventDelivery
  # notifications, so this skips generating them entirely — no structs allocated only
  # to be discarded, and none of the "Missed N notifications" noise that would
  # otherwise surface in host applications' own test runs.
  #
  # `sorted?: true` aligns `records` with the input order so each delivery maps back
  # to its spec's `coalesce?`/`failure_kind` flags. `stop_on_error?: true` + raising
  # on a non-success status preserves the bang contract: a genuine DB failure rolls
  # back the whole batch (leaving the events undispatched for the lease to re-emit).
  defp materialize_batch!([]), do: :ok

  defp materialize_batch!(specs) do
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
        authorize?: false,
        batch_size: length(specs)
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

  # Collect the DISTINCT `(subscription_id, event_key)` lanes that received a new,
  # coalescing `:pending` delivery in this batch, then cancel their superseded
  # siblings in ONE set-based UPDATE. A `notify_on_every_change` subscription baked
  # `coalesce?: false` into its specs, so its lanes never enter the list.
  defp coalesce_pending!(specs, deliveries) do
    lanes =
      specs
      |> Enum.zip(deliveries)
      |> Enum.filter(fn {%{coalesce?: coalesce?}, delivery} ->
        coalesce? and delivery.state == :pending
      end)
      |> Enum.map(fn {_spec, delivery} -> {delivery.subscription_id, delivery.event_key} end)
      |> Enum.uniq()

    if lanes != [], do: coalesce_superseded!(lanes)
    :ok
  end

  # ── Coalescing (latest-state) — per (subscription_id, event_key) ────────────
  # Cancel the `:pending` siblings superseded by a newer same-key delivery, keeping
  # the newest — for EVERY affected lane in the batch at once. A `:parked` sibling
  # freezes coalescing (the lane is held for an operator to fix). One atomic set-based
  # UPDATE joined against a `VALUES` list of the batch's lanes — there is no
  # read→write window, so it can't race the scheduler promoting a sibling to
  # `:scheduled`. Runs inside the batch transaction, so it commits with the inserts;
  # a DB failure raises and rolls the whole batch back, matching the bang inserts.
  defp coalesce_superseded!(lanes) do
    table = AshPostgres.DataLayer.Info.table(AshIntegration.event_delivery_resource())

    # `$1` is the shared cancel reason; each lane contributes a `(subscription_id,
    # event_key)` row to the VALUES list at `$2n`/`$2n+1`. The first row carries the
    # column casts so Postgres infers the tuple types for the whole list.
    {value_rows, lane_params} =
      lanes
      |> Enum.with_index()
      |> Enum.map(fn {{subscription_id, event_key}, index} ->
        base = 2 + index * 2
        {sub_cast, key_cast} = if index == 0, do: {"::uuid", "::text"}, else: {"", ""}

        {"($#{base}#{sub_cast}, $#{base + 1}#{key_cast})",
         [Ecto.UUID.dump!(subscription_id), event_key]}
      end)
      |> Enum.unzip()

    # Per lane, cancel every `:pending` row older than the newest `:pending`/`:parked`
    # sibling (UUIDv7 `event_id` = occurrence order), so the newest is kept.
    # `NOT EXISTS` a `:parked` sibling preserves the freeze — any parked → nothing is
    # cancelled for that lane. `RETURNING` drives the per-lane telemetry below.
    sql = """
    UPDATE #{table} AS d
    SET state = 'cancelled', last_error = $1, updated_at = now()
    FROM (VALUES #{Enum.join(value_rows, ", ")}) AS lanes(subscription_id, event_key)
    WHERE d.subscription_id = lanes.subscription_id
      AND d.event_key = lanes.event_key
      AND d.state = 'pending'
      AND d.event_id < (
        SELECT s.event_id FROM #{table} s
        WHERE s.subscription_id = lanes.subscription_id AND s.event_key = lanes.event_key
          AND s.state IN ('pending', 'parked')
        ORDER BY s.event_id DESC
        LIMIT 1
      )
      AND NOT EXISTS (
        SELECT 1 FROM #{table} p
        WHERE p.subscription_id = lanes.subscription_id AND p.event_key = lanes.event_key
          AND p.state = 'parked'
      )
    RETURNING d.subscription_id::text, d.event_key, d.event_type
    """

    params = ["Superseded by a newer event (coalesced)" | List.flatten(lane_params)]

    case AshIntegration.repo().query(sql, params) do
      {:ok, %{rows: rows}} -> report_coalesced(rows)
      {:error, error} -> raise "coalesce UPDATE failed: #{inspect(error)}"
    end

    :ok
  end

  # One log line + telemetry event per lane that actually dropped rows (preserving the
  # previous per-`(subscription, event_key)` granularity), grouped from the UPDATE's
  # `RETURNING`. `event_type` is functionally determined by the subscription, so it is
  # constant within a lane.
  defp report_coalesced(rows) do
    rows
    |> Enum.group_by(fn [subscription_id, event_key, event_type] ->
      {subscription_id, event_key, event_type}
    end)
    |> Enum.each(fn {{subscription_id, event_key, event_type}, dropped} ->
      count = length(dropped)

      Logger.info(
        "Coalesced #{count} superseded pending delivery(ies) for subscription " <>
          "#{subscription_id} (event_key #{event_key})"
      )

      :telemetry.execute(
        [:ash_integration, :coalesce, :events_dropped],
        %{count: count},
        %{
          subscription_id: subscription_id,
          event_type: event_type,
          event_key: event_key
        }
      )
    end)
  end
end
