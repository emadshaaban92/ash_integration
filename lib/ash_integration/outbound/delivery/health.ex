defmodule AshIntegration.Outbound.Delivery.Health do
  @moduledoc """
  Derived connection/subscription **suspension** and **bounded recovery probes** —
  see `design/connection-health.md`.

  Two periodic, idempotent passes over the delivery `Log`, both safe to run on
  every node (filtered transition writes + `SKIP LOCKED` carry correctness, never
  an elected singleton):

    * `recompute/0` — for each scope, a connection/subscription is suspended iff
      **none of its last `window_attempts` transport-relevant outcomes succeeded**.
      Reads the per-scope partial window index (`status = 'success' OR
      failure_class = '<class>'`, top-N by `id`) and writes `suspended` only on a
      transition, so the per-failure hot-row write is gone.
    * `probe/0` — picks at most `probe_batch` suspended entities (oldest-probed
      first, derived from each one's most recent transport `Log` row) and ensures
      each has exactly one live `:scheduled` delivery, so the normal relay can
      observe a recovery. A probe success clears the suspension on the next
      recompute.

  Park (freeing delivery slots the moment a connection is suspended) rides the
  `:suspend` transition itself — see
  `AshIntegration.Outbound.Delivery.Changes.ParkOnSuspend`.

  Like the retention sweeper this GenServer validates its `:health` config slice
  at boot and exposes `recompute/0` / `probe/0` for direct calls (tests, manual
  runs).
  """
  use GenServer

  require Ash.Expr
  require Logger

  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage

  def opts_schema do
    [
      window_attempts: [
        type: :pos_integer,
        default: 5,
        doc: "N — consecutive transport-relevant failures (no success among the last N) to trip."
      ],
      recompute_interval_ms: [
        type: :pos_integer,
        default: :timer.seconds(60),
        doc:
          "How often the suspended sets are recomputed. Must exceed worst-case probe latency (the soft lease) so a probe success lands before re-evaluation."
      ],
      probe_interval_ms: [
        type: :pos_integer,
        default: :timer.seconds(30),
        doc: "How often the bounded probe pass runs."
      ],
      probe_batch: [
        type: :pos_integer,
        default: 3,
        doc: "M — suspended entities probed per tick. Keep well below the delivery concurrency."
      ]
    ]
  end

  @doc "Validate a `:health` opts keyword against `opts_schema/0`."
  def validate!(opts), do: NimbleOptions.validate!(opts, opts_schema())

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = validate!(Keyword.merge(Application.get_env(:ash_integration, :health, []), opts))

    schedule(:recompute, config[:recompute_interval_ms])
    schedule(:probe, config[:probe_interval_ms])

    {:ok,
     %{
       recompute_interval: config[:recompute_interval_ms],
       probe_interval: config[:probe_interval_ms]
     }}
  end

  @impl true
  def handle_info(:recompute, state) do
    run(&recompute/0, "recompute")
    schedule(:recompute, state.recompute_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:probe, state) do
    run(&probe/0, "probe")
    schedule(:probe, state.probe_interval)
    {:noreply, state}
  end

  defp run(fun, label) do
    fun.()
  rescue
    e -> Logger.error("AshIntegration health #{label} failed: #{Exception.message(e)}")
  end

  defp schedule(msg, interval), do: Process.send_after(self(), msg, interval)

  # ── Recompute ───────────────────────────────────────────────────────────────

  @doc "Recompute the suspended set for both scopes and write only the transitions."
  def recompute do
    Enum.each(scopes(), &recompute_scope/1)
  end

  # sobelow_skip ["SQL.Query"]
  defp recompute_scope(scope) do
    n = window_attempts()

    sql = """
    SELECT e.id::text, (w.n >= $1 AND NOT w.any_success) AS should_suspend, e.suspended
    FROM #{table(scope.resource)} e
    JOIN LATERAL (
      SELECT count(*) AS n, coalesce(bool_or(t.status = 'success'), false) AS any_success
      FROM (
        SELECT l.status
        FROM #{log_table()} l
        WHERE l.#{scope.id_column} = e.id
          AND (l.status = 'success' OR l.failure_class = '#{scope.failure_class}')
        ORDER BY l.id DESC
        LIMIT $1
      ) t
    ) w ON true
    WHERE e.id IN (
      SELECT DISTINCT #{scope.id_column} FROM #{log_table()}
      WHERE status = 'success' OR failure_class = '#{scope.failure_class}'
    )
    """

    %{rows: rows} = query!(sql, [n])

    Enum.each(rows, fn
      [id, true, false] -> suspend(scope, id)
      [id, false, true] -> unsuspend(scope, id)
      _ -> :ok
    end)
  end

  defp suspend(scope, id) do
    reason =
      "Auto-suspended: no successful #{scope.failure_class} delivery in the last " <>
        "#{window_attempts()} attempts"

    scope.resource
    |> Ash.get!(id, authorize?: false)
    |> Ash.Changeset.for_update(:suspend, %{reason: reason}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(suspended == false))
    |> Ash.update(authorize?: false, return_notifications?: true)
    |> case do
      {:ok, _record, _notifications} ->
        :telemetry.execute(
          [:ash_integration, scope.name, :suspended],
          %{count: 1},
          %{id: id, failure_class: scope.failure_class, window_attempts: window_attempts()}
        )

      {:error, _stale} ->
        :ok
    end
  end

  defp unsuspend(scope, id) do
    scope.resource
    |> Ash.get!(id, authorize?: false)
    |> Ash.Changeset.for_update(:unsuspend, %{}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(suspended == true))
    |> Ash.update(authorize?: false, return_notifications?: true)
    |> case do
      {:ok, _record, _notifications} -> :ok
      {:error, _stale} -> :ok
    end
  end

  # ── Probe ─────────────────────────────────────────────────────────────────────

  @doc "Run one bounded probe pass for both scopes."
  def probe do
    Enum.each(scopes(), &probe_scope/1)
  end

  # sobelow_skip ["SQL.Query"]
  defp probe_scope(scope) do
    sql = """
    SELECT e.id::text
    FROM #{table(scope.resource)} e
    JOIN LATERAL (
      SELECT l.id AS last_log_id
      FROM #{log_table()} l
      WHERE l.#{scope.id_column} = e.id
        AND (l.status = 'success' OR l.failure_class = '#{scope.failure_class}')
      ORDER BY l.id DESC
      LIMIT 1
    ) ll ON true
    WHERE e.suspended = true
    ORDER BY ll.last_log_id ASC
    LIMIT $1
    """

    %{rows: rows} = query!(sql, [probe_batch()])

    Enum.each(rows, fn [id] ->
      unless has_live_probe?(scope, id), do: promote_probe(scope, id)
      :telemetry.execute([:ash_integration, scope.name, :probe], %{count: 1}, %{id: id})
    end)
  end

  # A live probe is any non-poison `:scheduled` row for the entity — after the park
  # on suspend that is the only `:scheduled` row it can have.
  # sobelow_skip ["SQL.Query"]
  defp has_live_probe?(scope, id) do
    sql = """
    SELECT 1 FROM #{ed_table()}
    WHERE #{scope.id_column} = $1 AND state = 'scheduled' AND attempts < $2
    LIMIT 1
    """

    %{num_rows: n} = query!(sql, [Ecto.UUID.dump!(id), Stage.max_attempts()])
    n > 0
  end

  # Promote the entity's oldest `:pending` head whose lane has no in-flight row, so
  # the normal relay claims exactly one probe delivery. Lane uniqueness is keyed on
  # `(connection_id, event_key)` for both scopes.
  # sobelow_skip ["SQL.Query"]
  defp promote_probe(scope, id) do
    sql = """
    UPDATE #{ed_table()} SET state = 'scheduled', claimed_at = NULL, next_attempt_at = NULL
    WHERE id = (
      SELECT d.id FROM #{ed_table()} d
      WHERE d.#{scope.id_column} = $1 AND d.state = 'pending'
        AND NOT EXISTS (
          SELECT 1 FROM #{ed_table()} s
          WHERE s.connection_id = d.connection_id
            AND s.event_key = d.event_key
            AND s.state = 'scheduled'
        )
      ORDER BY d.event_id ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    """

    query!(sql, [Ecto.UUID.dump!(id)])
  end

  # ── Scopes / config / repo ──────────────────────────────────────────────────

  defp scopes do
    [
      %{
        name: :connection,
        id_column: "connection_id",
        failure_class: "transport",
        resource: AshIntegration.connection_resource()
      },
      %{
        name: :subscription,
        id_column: "subscription_id",
        failure_class: "response",
        resource: AshIntegration.subscription_resource()
      }
    ]
  end

  def window_attempts, do: Keyword.fetch!(config(), :window_attempts)
  defp probe_batch, do: Keyword.fetch!(config(), :probe_batch)

  defp config, do: validate!(Application.get_env(:ash_integration, :health, []))

  defp log_table, do: table(AshIntegration.delivery_log_resource())
  defp ed_table, do: table(AshIntegration.event_delivery_resource())
  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp query!(sql, params) do
    AshIntegration.repo().query!(sql, params, log: AshIntegration.query_log_level())
  end
end
