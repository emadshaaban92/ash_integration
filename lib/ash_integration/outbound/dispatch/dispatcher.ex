defmodule AshIntegration.Outbound.Dispatch.Dispatcher do
  @moduledoc """
  Outbox **claim + bookkeeping** for the dispatch relay.

  Fan-out lives in the Event `:dispatch` bulk action: prep (the host's `project/3`
  + the Lua transform) runs in the Broadway processor stage via
  `AshIntegration.Outbound.Dispatch.Specs`, and the change module
  `AshIntegration.Outbound.Dispatch.Changes.DispatchEvent` materializes the deliveries +
  coalesces **atomically** with the `dispatched_at` stamp inside the batch
  transaction. This module provides the claim and bookkeeping around that action:

    * `claim/1` — atomically lease undispatched `Event`s (`FOR UPDATE SKIP LOCKED`
      + soft lease, oldest first, attempt-ceiling) for the relay's producer. The
      atomic claim is what makes parallel/multi-node relays safe; `bulk_update`
      gives no cross-node lease.
    * `subscriptions_for/2` — the candidate subscriptions on a `(type, version)`,
      with the connection (+owner) loaded. Shared by the relay's `prepare_messages`.
    * `record_dispatch_errors/1` — record a `dispatch_error` on the *failed* path
      (relay ack / poison), never stamping `dispatched_at`.

  Un-sticking a poison event (operator recourse) is just the Event's
  `:reset_dispatch` action (reset the bookkeeping so `claim/1` picks it up again);
  the relay re-attempts it on its next poll.

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
  bumps `dispatch_attempts` (the retry ceiling), then reloads the full structs by id
  (so the host's `project/3` sees real `Event.t()` records).

  The lease UPDATE and the reload run in **one transaction**: the UPDATE commits the
  lease + attempt bump, and if the reload then fails on a transient DB blip the whole
  claim rolls back. Without that, a committed-but-unreloaded row would be leased yet
  never emitted — invisible for a full lease window, its `dispatch_attempts` silently
  burned toward the ceiling with no `dispatch_error` ever recorded. On any failure the
  claim yields `[]` and the next poll retries cleanly.

  Events at/over `dispatch_max_attempts` are **never claimed again** — they are
  terminal (poison). We deliberately do **not** auto-resolve them: the row stays in
  the outbox (`dispatched_at` NULL) and its `(connection, event_key)` lane stays
  blocked by the high-water gate until a human (or a host-app change) intervenes.
  """
  def claim(limit) when is_integer(limit) and limit > 0 do
    repo = AshIntegration.repo()
    resource = AshIntegration.event_resource()
    table = AshPostgres.DataLayer.Info.table(resource)
    lease = Stage.lease_seconds()
    max_attempts = Stage.max_attempts()

    # The inner SELECT picks the oldest claimable rows (unleased or lease-expired,
    # still undispatched, under the attempt ceiling) and locks them SKIP LOCKED; the
    # outer UPDATE stamps the lease + bumps the attempt counter, all in one statement
    # so two claimers can never grab the same row.
    sql = """
    UPDATE #{table} AS e
    SET claimed_at = now(), dispatch_attempts = e.dispatch_attempts + 1
    FROM (
      SELECT id FROM #{table}
      WHERE dispatched_at IS NULL
        AND dispatch_attempts < $2
        AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $1))
      ORDER BY id ASC
      LIMIT $3
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
        case claim_and_load(repo, sql, [lease, max_attempts, limit]) do
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

  # ── Failed-path bookkeeping (dispatch_error + poison) ───────────────────────

  @doc """
  Record a per-event `dispatch_error` for events whose dispatch failed at the infra
  level (left `dispatched_at` NULL → the lease expires → they are re-emitted).
  Visibility only — it never stamps `dispatched_at`. Takes `[{event_id, reason}]`.

  An event that has reached `dispatch_max_attempts` is **terminal**: `claim/1`
  excludes it, so it won't be retried, and we record a poison-flavoured
  `dispatch_error` + emit `[:ash_integration, :dispatch, :poison]` telemetry. This
  fires exactly once — the attempt that crossed the ceiling. We still do **not**
  stamp `dispatched_at`: the event stays stuck and its lane blocked, by design.
  Find terminal events with `dispatched_at IS NULL AND dispatch_attempts >= N`.
  """
  def record_dispatch_errors([]), do: :ok

  def record_dispatch_errors(id_reasons) when is_list(id_reasons) do
    max_attempts = Stage.max_attempts()
    reason_by_id = Map.new(id_reasons, fn {event_id, reason} -> {to_string(event_id), reason} end)

    # One read for the whole failed batch instead of a `get` per event — a
    # whole-batch infra failure otherwise turns the ack into N `get`s + N updates.
    # Ids absent from the outbox simply don't come back (nothing to record).
    AshIntegration.event_resource()
    |> Ash.Query.filter(id in ^Map.keys(reason_by_id))
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn event ->
      reason = Map.fetch!(reason_by_id, to_string(event.id))
      # Runs the poison side effects (operator log + telemetry) exactly once per
      # terminal event, and yields this event's `dispatch_error` string.
      {truncate(dispatch_error_for(event, reason, max_attempts)), event}
    end)
    # Group by the resolved message so each distinct `dispatch_error` is written in
    # a single `bulk_update`. A whole-batch infra failure shares one reason across
    # all (non-terminal) events, so it collapses to ONE update query.
    |> Enum.group_by(fn {error, _event} -> error end, fn {_error, event} -> event end)
    |> Enum.each(fn {dispatch_error, events} ->
      record_group(events, dispatch_error)
    end)

    :ok
  end

  defp record_group(events, dispatch_error) do
    result =
      Ash.bulk_update(events, :mark_dispatched, %{dispatch_error: dispatch_error},
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
            "#{length(events)} event(s): #{inspect(result.errors)}"
        )

      _ ->
        :ok
    end
  end

  # A terminal (poison) event — it has burned through every dispatch attempt, so
  # `claim/1` will never pick it up again. We surface it loudly (operator log +
  # telemetry) and stamp a poison-flavoured `dispatch_error`, but deliberately leave
  # `dispatched_at` NULL so the event stays stuck and its lane blocked until someone
  # resolves it. We NEVER auto-resolve (correctness over liveness): silently stamping
  # a never-dispatched event would drop it and let a newer same-key event deliver
  # ahead of it. A host wanting different behaviour can add its own change on the
  # `Event` resource — the library won't.
  defp dispatch_error_for(%{dispatch_attempts: attempts} = event, reason, max_attempts)
       when attempts >= max_attempts do
    Logger.error(
      "Outbound dispatch: poison event #{event.id} (#{event.event_type}, key " <>
        "#{event.event_key}) stuck after #{attempts} dispatch attempts — left " <>
        "undispatched, lane blocked (no auto-resolve); last error: #{reason}"
    )

    :telemetry.execute(
      [:ash_integration, :dispatch, :poison],
      %{attempts: attempts},
      %{event_id: event.id, event_type: event.event_type, event_key: event.event_key}
    )

    "poison: stuck after #{attempts} dispatch attempts (no auto-resolve; left " <>
      "undispatched, lane blocked); last error: #{reason}"
  end

  defp dispatch_error_for(_event, reason, _max_attempts), do: reason

  # dispatch_error is a bounded string column; keep operator messages readable.
  defp truncate(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp truncate(reason), do: reason |> inspect() |> String.slice(0, 500)
end
