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
end
