defmodule AshIntegration.Inbound.Execute.Claimer do
  @moduledoc """
  Atomic **claim** over the `CommandExecution` table for the command relay — the
  inbound twin of `Outbound.Dispatch.Dispatcher.claim/1`.

  Claims **any** stale-or-unclaimed `:pending` row (not just `:response` rows), so
  the relay is the universal crash-recovery sweep: a push-transport consumer that
  died mid-apply left a leased `:pending` row; whichever arrives first — the
  broker's redelivery or this sweep — executes it, and the `claimed_at` fence
  arbitrates if both run. The relay can do this because the actor is snapshotted
  on the row, so it needs nothing from the transport to execute correctly.
  """

  require Logger

  alias AshIntegration.Inbound.Execute.Supervisor, as: Stage

  @doc """
  Atomically claim up to `limit` claimable `:pending` rows (oldest occurrence-id
  first) and return them as loaded structs. Stamps the `claimed_at` lease (the
  fence token) and bumps `attempts` in one statement, gated on: still `:pending`,
  under the attempt ceiling, backoff elapsed, and the lease free (null or older
  than the lease window). `FOR UPDATE SKIP LOCKED` makes parallel/multi-node
  claims disjoint.
  """
  def claim(limit) when is_integer(limit) and limit > 0 do
    repo = AshIntegration.repo()
    table = AshPostgres.DataLayer.Info.table(AshIntegration.command_execution_resource())
    lease = Stage.lease_seconds()
    max_attempts = Stage.max_attempts()

    sql = """
    UPDATE #{table} AS c
    SET claimed_at = now(), attempts = c.attempts + 1
    FROM (
      SELECT id FROM #{table}
      WHERE state = 'pending'
        AND attempts < $2
        AND (next_attempt_at IS NULL OR next_attempt_at <= now())
        AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $1))
      ORDER BY id ASC
      LIMIT $3
      FOR UPDATE SKIP LOCKED
    ) AS claimable
    WHERE c.id = claimable.id
    RETURNING c.id::text
    """

    case repo.query(sql, [lease, max_attempts, limit], log: AshIntegration.query_log_level()) do
      {:ok, %{rows: rows}} ->
        rows |> Enum.map(fn [id] -> id end) |> load_claimed()

      {:error, error} ->
        Logger.error("Inbound command: claim query failed: #{inspect(error)}")
        []
    end
  end

  defp load_claimed([]), do: []

  defp load_claimed(ids) do
    require Ash.Query

    AshIntegration.command_execution_resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    # Preserve the claim's FIFO order (the read does not guarantee it).
    |> Enum.sort_by(& &1.id)
  end

  @reap_reason "dead-lettered by reaper: stranded :pending at the attempt ceiling " <>
                 "(a worker crashed after the claim that hit the ceiling, before any finalize)"

  @doc """
  Dead-letter `:pending` rows that are **at or over the attempt ceiling** and whose
  lease has expired — the one case the normal flow can't resolve.

  `claim/1`'s gate is `attempts < max_attempts`, and `attempts` is bumped at claim
  time and committed independently of execution. A hard crash after the claim that
  bumped `attempts` to exactly `max_attempts`, but before any finalize commits,
  leaves the row `:pending` at the ceiling: the lease expires, yet the next claim's
  `max_attempts < max_attempts` is false, so it would never be re-claimed, executed,
  or dead-lettered — and retention never reaps `:pending`. This sweep closes that
  gap, restoring the "bounds a crash loop" guarantee.

  The lease guard in the `WHERE` makes it race-safe: a row a worker just claimed
  (fresh `claimed_at`) does not match, so an in-flight row is never dead-lettered
  out from under its executor. Returns the number of rows reaped.
  """
  def reap_exhausted do
    repo = AshIntegration.repo()
    table = AshPostgres.DataLayer.Info.table(AshIntegration.command_execution_resource())
    lease = Stage.lease_seconds()
    max_attempts = Stage.max_attempts()

    sql = """
    UPDATE #{table}
    SET state = 'dead_lettered', error = $1, claimed_at = NULL
    WHERE state = 'pending'
      AND attempts >= $2
      AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $3))
    RETURNING id::text
    """

    case repo.query(sql, [@reap_reason, max_attempts, lease],
           log: AshIntegration.query_log_level()
         ) do
      {:ok, %{rows: rows}} ->
        report_reaped(rows)

      {:error, error} ->
        Logger.error("Inbound command: reap query failed: #{inspect(error)}")
        0
    end
  end

  defp report_reaped([]), do: 0

  defp report_reaped(rows) do
    count = length(rows)

    Logger.warning(
      "Inbound command: dead-lettered #{count} stranded :pending row(s) at/over the attempt " <>
        "ceiling (a worker likely crashed after the final claim). Operator `retry` is the recourse."
    )

    :telemetry.execute(
      [:ash_integration, :command, :dead_lettered],
      %{count: count},
      %{reason: :ceiling_stranded}
    )

    count
  end
end
