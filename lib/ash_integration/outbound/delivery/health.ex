defmodule AshIntegration.Outbound.Delivery.Health do
  @moduledoc """
  Derived connection/subscription **suspension** — see `design/connection-health.md`.

  A periodic, idempotent pass over the delivery `Log`, safe to run on every node
  (filtered transition writes carry correctness, never an elected singleton):

    * `recompute/0` — for each scope, a connection/subscription is suspended iff
      **none of its last `window_attempts` transport-relevant outcomes succeeded**.
      Reads the per-scope partial window index (`status = 'success' OR
      failure_class = '<class>'`, top-N by `id`) and writes `suspended` only on a
      transition, so the per-failure hot-row write is gone.

  Park (freeing delivery slots the moment a connection is suspended) rides the
  `:suspend` transition itself — see
  `AshIntegration.Outbound.Delivery.Changes.ParkOnSuspend`.

  Recovery in this phase is **manual** (the retained `unsuspend` action), exactly
  as before — the hot-row write and the slot pressure are what change. The bounded
  automatic-recovery probe is a later phase (design §13), deferred so it can reuse
  the scheduler's schedulable-head query rather than re-derive a thinner, drift-prone
  copy of its ordering gates.

  Like the retention sweeper this GenServer validates its `:health` config slice
  at boot and exposes `recompute/0` for direct calls (tests, manual runs).
  """
  use GenServer

  require Ash.Expr
  require Logger

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
        doc: "How often the suspended sets are recomputed."
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
    {:ok, %{recompute_interval: config[:recompute_interval_ms]}}
  end

  @impl true
  def handle_info(:recompute, state) do
    try do
      recompute()
    rescue
      e -> Logger.error("AshIntegration health recompute failed: #{Exception.message(e)}")
    end

    schedule(:recompute, state.recompute_interval)
    {:noreply, state}
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

  defp config, do: validate!(Application.get_env(:ash_integration, :health, []))

  defp log_table, do: table(AshIntegration.delivery_log_resource())
  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp query!(sql, params) do
    AshIntegration.repo().query!(sql, params, log: AshIntegration.query_log_level())
  end
end
