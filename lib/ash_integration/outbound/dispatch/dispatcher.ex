defmodule AshIntegration.Outbound.Dispatch.Dispatcher do
  @moduledoc """
  Outbox **claim + bookkeeping** for the dispatch relay.

  Fan-out lives in the Event `:dispatch` bulk action: prep (the host's `project/3`
  + the Lua transform) runs in the Broadway processor stage via
  `AshIntegration.Outbound.Dispatch.Specs`, and the change module
  `AshIntegration.Outbound.Dispatch.Changes.DispatchEvent` materializes the deliveries +
  coalesces **atomically** with the `dispatched_at` stamp inside the batch
  transaction. This module provides the claim and bookkeeping around that action:

    * `claim/1` — atomically lease undispatched, non-terminal `Event`s (`FOR UPDATE
      SKIP LOCKED` + soft lease, oldest first) for the relay's producer. The atomic
      claim is what makes parallel/multi-node relays safe; `bulk_update` gives no
      cross-node lease.
    * `subscriptions_for/2` — the candidate subscriptions on a `(type, version)`,
      with the connection (+owner) loaded. Shared by the relay's `prepare_messages`.
    * `record_dispatch_errors/1` — record a `dispatch_error` on the *failed* path
      (relay ack), for visibility; never stamps `dispatched_at`, never decides
      terminal-ness.
    * `sweep_expired/0` — the opt-in age-based give-up: take undispatched Events
      older than `max_dispatch_age_ms` terminal (`dispatch_terminal_reason:
      :expired`). Driven by the `Retention` GenServer's tick; a no-op unless an age
      is configured. See `design/dispatch-terminal-model.md`.
    * `reset_terminal/0` — the bulk operator affordance: clear the terminal bit on
      every stuck Event in one `:reset_dispatch` bulk update.

  Un-sticking a terminal (`:expired`) event (operator recourse) is the Event's
  `:reset_dispatch` action (clear the terminal bit so `claim/1` picks it up again);
  the relay re-attempts it on its next poll. There is **no attempt ceiling** —
  `dispatch_attempts` is an honest, monotonic counter, never a verdict — so a
  transient infra failure can never poison the backlog.

  Because the stamp and the deliveries commit together, a committed event is never
  re-claimed (`claim/1` filters `dispatched_at IS NULL`) and a rolled-back batch
  commits nothing, so no per-row idempotency check is needed.
  """

  require Ash.Query
  require Logger

  alias AshIntegration.Outbound.Dispatch.Supervisor, as: Stage

  # ── Candidate subscriptions for a (type, version) ──────────────────────────

  @doc """
  Candidate subscriptions on this `(event_type, version)`, with the connection
  owner loaded (`project` may scope on it). Gated on both subscription and
  connection being `active`; suspended ones are INCLUDED so suspension never loses
  data (the scheduler decides whether a suspended route may deliver). Used by the
  relay's `prepare_messages`.
  """
  def subscriptions_for(event_type, version) do
    AshIntegration.subscription_resource()
    |> Ash.Query.filter(
      event_type == ^event_type and version == ^version and
        active == true and connection.active == true
    )
    |> Ash.Query.load(connection: [:owner])
    |> Ash.read!(authorize?: false)
  end

  # ── Claim (the outbox cursor over `Event.dispatched_at`) ────────────────────

  @doc """
  Atomically claim up to `limit` undispatched `Event`s for fan-out and return them
  as loaded resource structs, oldest (`id`, UUIDv7) first.

  Uses `... FOR UPDATE SKIP LOCKED` so multiple relay passes/nodes claim disjoint
  rows in parallel — **safe only because the scheduler high-water gate owns
  ordering correctness**, not claim order. Stamps a soft `claimed_at` lease and
  bumps `dispatch_attempts` (an honest, monotonic counter — never a ceiling), then
  reloads the full structs by id (so the host's `project/3` sees real `Event.t()`
  records).

  The lease UPDATE and the reload run in **one transaction**: the UPDATE commits the
  lease + attempt bump, and if the reload then fails on a transient DB blip the whole
  claim rolls back. Without that, a committed-but-unreloaded row would be leased yet
  never emitted — invisible for a full lease window, its `dispatch_attempts` silently
  bumped for work never done, with no `dispatch_error` ever recorded. On any failure
  the claim yields `[]` and the next poll retries cleanly.

  Terminal (`:expired`) events — `dispatch_terminal_reason IS NOT NULL` — are **never
  claimed again**. We deliberately do **not** auto-resolve them: the row stays in the
  outbox (`dispatched_at` NULL) and its `(connection, event_key)` lane stays blocked
  by the high-water gate until an operator `:reset_dispatch`es it (or raises the age
  policy). Terminal-ness comes only from the opt-in age sweep — never from an attempt
  count — so infra flakiness can never make a row terminal.
  """
  def claim(limit) when is_integer(limit) and limit > 0 do
    repo = AshIntegration.repo()
    resource = AshIntegration.event_resource()
    table = AshPostgres.DataLayer.Info.table(resource)
    lease = Stage.lease_seconds()

    # The inner SELECT picks the oldest claimable rows (unleased or lease-expired,
    # still undispatched, not terminal) and locks them SKIP LOCKED; the outer UPDATE
    # stamps the lease + bumps the (non-gating) attempt counter, all in one statement
    # so two claimers can never grab the same row.
    sql = """
    UPDATE #{table} AS e
    SET claimed_at = now(), dispatch_attempts = e.dispatch_attempts + 1
    FROM (
      SELECT id FROM #{table}
      WHERE dispatched_at IS NULL
        AND dispatch_terminal_reason IS NULL
        AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $1))
      ORDER BY id ASC
      LIMIT $2
      FOR UPDATE SKIP LOCKED
    ) AS claimable
    WHERE e.id = claimable.id
    RETURNING e.id::text
    """

    # UPDATE (lease + bump) and reload share ONE transaction, opened directly on the repo
    # so we can pass `log:` — the begin/commit envelope then honours `query_log_level` just
    # like the claim UPDATE (`Ash.transact` can't forward `:log`, so with it the bare
    # begin/commit leaked at `:debug` even when the claim query was silenced). Ecto's
    # `Repo.transaction` does NOT roll back on an `{:error, _}` return, only on a raise or an
    # explicit `rollback/1`, so on a UPDATE/reload blip we call `repo.rollback(reason)`
    # ourselves — that keeps the "never leased-but-unemitted" guarantee: the lease + attempt
    # bump roll back with the reload, leaving the rows claimable. Any failure yields [].
    repo.transaction(
      fn ->
        case claim_and_load(repo, sql, [lease, limit]) do
          {:error, reason} -> repo.rollback(reason)
          events -> events
        end
      end,
      log: AshIntegration.query_log_level()
    )
    |> case do
      {:ok, events} ->
        events

      {:error, error} ->
        Logger.error("Outbound dispatch: claim failed: #{inspect(error)}")
        []
    end
  rescue
    # `Repo.transaction` re-raises if the function raises (e.g. a pool-checkout timeout on
    # the UPDATE itself); the transaction has already rolled back. A claim must never
    # crash the producer — hold the demand and let the next poll retry.
    e ->
      Logger.error("Outbound dispatch: claim failed: #{Exception.message(e)}")
      []
  end

  # Runs inside the claim transaction: lease UPDATE, then reload by id. Returns the bare
  # loaded events (so the transaction commits and yields `{:ok, _}`) or `{:error, reason}`
  # on a UPDATE/reload failure (the caller then `rollback/1`s to undo the lease).
  defp claim_and_load(repo, sql, params) do
    with {:ok, %{rows: rows}} <-
           repo.query(sql, params, log: AshIntegration.query_log_level()),
         {:ok, events} <- rows |> Enum.map(fn [id] -> id end) |> load_claimed() do
      events
    end
  end

  defp load_claimed([]), do: {:ok, []}

  defp load_claimed(ids) do
    AshIntegration.event_resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(authorize?: false)
    |> case do
      # Preserve the claim's FIFO order (the read does not guarantee it), so the
      # relay's batches tend to see events in id (occurrence) order.
      {:ok, events} -> {:ok, Enum.sort_by(events, & &1.id)}
      {:error, error} -> {:error, error}
    end
  end

  # ── Failed-path bookkeeping (dispatch_error, visibility only) ───────────────

  @doc """
  Record a per-event `dispatch_error` for events whose dispatch failed at the infra
  level (left `dispatched_at` NULL → the lease expires → they are re-emitted).
  Visibility only — it never stamps `dispatched_at` and never decides terminal-ness.
  Takes `[{event_id, reason}]`.

  Terminal-ness is not this path's job: with no attempt ceiling, a failed dispatch is
  just re-emitted, and only the opt-in age sweep (`sweep_expired/0`) can take a row
  terminal. So this simply stamps the raw reason on each row, coalescing a
  shared-reason (whole-batch infra) failure into one `bulk_update`.
  """
  def record_dispatch_errors([]), do: :ok

  def record_dispatch_errors(id_reasons) when is_list(id_reasons) do
    id_reasons
    # Group by the reason so each distinct `dispatch_error` is written in a single
    # `bulk_update`. A whole-batch infra failure shares one reason across all events,
    # so it collapses to ONE update query.
    |> Enum.group_by(fn {_id, reason} -> truncate(reason) end, fn {id, _reason} -> id end)
    |> Enum.each(fn {dispatch_error, ids} -> record_group(ids, dispatch_error) end)

    :ok
  end

  defp record_group(ids, dispatch_error) do
    result =
      AshIntegration.event_resource()
      |> Ash.Query.filter(id in ^ids)
      |> Ash.bulk_update(:mark_dispatched, %{dispatch_error: dispatch_error},
        # `:atomic_batches` writes each group in one `UPDATE ... WHERE id = ANY(...)`;
        # `:stream` is the fallback if a host adds a non-atomic change to the seam.
        strategy: [:atomic_batches, :stream],
        return_records?: false,
        return_errors?: true,
        # Ack path: don't emit Ash notifications for a visibility-only error stamp.
        notify?: false,
        authorize?: false
      )

    case result.status do
      :error ->
        Logger.error(
          "Outbound dispatch: recording dispatch_error failed for " <>
            "#{length(ids)} event(s): #{inspect(result.errors)}"
        )

      _ ->
        :ok
    end
  end

  # ── Age-based give-up (opt-in `:expired`) + operator recovery ───────────────

  @doc """
  Opt-in give-up policy: take any undispatched, non-terminal, **unleased** Event whose
  age (from `created_at`) exceeds `Supervisor.max_dispatch_age_ms/0` terminal — set
  `dispatch_terminal_reason: :expired`, so `claim/1` stops picking it up and its
  `(connection, event_key)` lane stays blocked like any terminal head. A row still
  inside its `lease_seconds` window is skipped: it may be mid-fan-out on another
  pass/node, and expiring it concurrently could leave it BOTH dispatched AND
  `:expired`. No-op unless the age is configured (`nil` = never expire, the safe
  default). Idempotent (matches only `dispatch_terminal_reason IS NULL`) and safe on
  every node. Driven by the `Retention` GenServer's tick — mirrors how the delivery
  age sweep rides `Health`.
  """
  def sweep_expired do
    case Stage.max_dispatch_age_ms() do
      nil -> :ok
      age_ms when is_integer(age_ms) and age_ms > 0 -> expire_older_than(age_ms)
    end
  end

  # One bulk `:expire_dispatch` through Ash (not raw SQL) so `updated_at` bumps and
  # host notifiers see the transition. The query-side guard (`dispatched_at IS NULL`,
  # `dispatch_terminal_reason IS NULL`) is the action's precondition, pushed here the
  # same way the delivery sweep pushes its `:failed`/`terminal_reason` guard;
  # `SetAttribute` is atomic-capable, so `:atomic` runs this as a single UPDATE.
  #
  # It ALSO skips lease-held rows (`claimed_at` still inside `lease_seconds`): after an
  # outage recovery the relay can be actively fanning out an old, still-leased event
  # while this sweep runs, and expiring it mid-dispatch would leave a row BOTH
  # dispatched AND `:expired` if the dispatch txn then wins. Only an unleased or
  # lease-expired row (no live claimer) is a give-up candidate. `DispatchEvent`'s
  # `batch_change` force-clears the terminal bit as the other end of this belt-and-
  # braces, so even a claim landing in the narrow post-filter window can't leave the
  # stale artifact behind.
  defp expire_older_than(age_ms) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -age_ms, :millisecond)
    lease_cutoff = DateTime.add(now, -Stage.lease_seconds(), :second)

    result =
      AshIntegration.event_resource()
      |> Ash.Query.filter(
        is_nil(dispatched_at) and is_nil(dispatch_terminal_reason) and created_at < ^cutoff and
          (is_nil(claimed_at) or claimed_at < ^lease_cutoff)
      )
      |> Ash.bulk_update(:expire_dispatch, %{},
        strategy: [:atomic, :stream],
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        notify?: true
      )

    n =
      case result do
        %Ash.BulkResult{records: records} when is_list(records) ->
          length(records)

        %Ash.BulkResult{errors: errors} ->
          Logger.error("Outbound dispatch: expiry sweep failed: #{inspect(errors)}")
          0
      end

    if n > 0 do
      Logger.warning(
        "Outbound dispatch: expired #{n} undispatched event(s) older than #{age_ms}ms " <>
          "— terminal (`:expired`), lanes blocked (no auto-resolve)."
      )

      :telemetry.execute([:ash_integration, :dispatch, :expired], %{count: n}, %{
        max_dispatch_age_ms: age_ms
      })
    end

    :ok
  end

  @doc """
  Bulk operator affordance: clear the terminal bit on every stuck (`:expired`) Event
  in one `:reset_dispatch` bulk update, so `claim/1` re-picks them up. Returns the
  count reset. Use after resolving the cause of a mass stall (e.g. a long DB outage
  that outlived the configured `max_dispatch_age_ms`) instead of resetting rows one
  at a time. Leaves `dispatched_at` untouched, so it can never resurrect a dispatched
  event.
  """
  def reset_terminal do
    result =
      AshIntegration.event_resource()
      |> Ash.Query.filter(is_nil(dispatched_at) and not is_nil(dispatch_terminal_reason))
      |> Ash.bulk_update(:reset_dispatch, %{},
        # `:reset_dispatch` is a record-based (non-atomic) change, so `:stream`.
        strategy: [:stream],
        return_records?: true,
        return_errors?: true,
        notify?: false,
        authorize?: false
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, length(records)}

      %Ash.BulkResult{errors: errors} ->
        Logger.error("Outbound dispatch: bulk reset_terminal failed: #{inspect(errors)}")
        {:error, errors}
    end
  end

  # dispatch_error is a bounded string column; keep operator messages readable.
  defp truncate(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp truncate(reason), do: reason |> inspect() |> String.slice(0, 500)
end
