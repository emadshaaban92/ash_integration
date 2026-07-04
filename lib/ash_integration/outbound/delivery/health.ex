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
    * `probe/0` — picks at most `probe_batch` suspended entities per scope
      (oldest-probed-first, derived from each one's most recent `Log` row) that have
      no live `:scheduled` delivery, and asks the **scheduler** to promote one
      schedulable head each so the relay can observe a recovery. A probe success
      clears the suspension on the next recompute. Promotion is delegated to
      `Scheduler.promote_probe/2` — the probe is held to the exact ordering gates of
      a normal promotion, never a re-derived subset.

  There is no separate "park on suspend" step: a suspended entity's waiting deliveries
  already sit in `:failed` (held-waiting), and the scheduler simply stops promoting a
  suspended entity, so nothing needs to be drained. The recompute tick also runs
  `sweep_expired/0` — the opt-in age-based give-up (`terminal_reason: :expired`), a
  no-op unless `Supervisor.max_delivery_age_ms/0` is configured.

  Like the retention sweeper this GenServer validates its `:health` config slice
  at boot and exposes `recompute/0` / `probe/0` / `sweep_expired/0` for direct calls
  (tests, manual runs).
  """
  use GenServer

  require Ash.Expr
  require Ash.Query
  require Logger

  alias AshIntegration.Outbound.Delivery.Scheduler
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
        default: default_recompute_interval_ms(),
        doc:
          "How often the suspended sets are recomputed. Must comfortably exceed the worst-case probe duration (the soft lease = http_max_timeout + margin), or a recovering entity's in-flight probe success won't have landed before re-evaluation — costing one extra interval of recovery latency (never a mis-flip; with no success logged yet the entity correctly stays suspended). The default is derived as lease + 30s so it scales with http_max_timeout rather than assuming a sub-30s timeout."
      ],
      probe_interval_ms: [
        type: :pos_integer,
        default: :timer.seconds(30),
        doc: "How often the bounded recovery probe pass runs."
      ],
      probe_batch: [
        type: :pos_integer,
        default: 3,
        doc:
          "M — suspended entities probed per scope per tick. Keep well below delivery concurrency."
      ]
    ]
  end

  # Recompute cadence derived from the soft lease (§13): a probe started right after
  # one recompute resolves within `lease` and is visible to the next, so the interval
  # must exceed the lease. lease + 30s keeps that margin at any `http_max_timeout`.
  defp default_recompute_interval_ms do
    Stage.lease_seconds() * 1000 + :timer.seconds(30)
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
    run(&sweep_expired/0, "sweep_expired")
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

  @doc "Run one bounded recovery-probe pass for both scopes."
  def probe do
    Enum.each(scopes(), &probe_scope/1)
  end

  defp probe_scope(scope) do
    Enum.each(pick_suspended(scope, probe_batch()), fn id ->
      result = Scheduler.promote_probe(scope.name, id)

      :telemetry.execute([:ash_integration, scope.name, :probe], %{count: 1}, %{
        id: id,
        promoted: result == :scheduled
      })
    end)
  end

  # The probe's policy: pick `m` suspended entities, **oldest-probed-first** — ordered
  # by each one's most recent transport/response `Log` row (for a suspended entity
  # that row IS its last probe, since the scheduler promotes no other traffic while
  # suspended) — skipping any that still hold an in-flight `:scheduled` delivery so a
  # probe is never stacked. (A suspended entity's other heads sit in `:failed`,
  # promoted only by the probe; a terminal `:failed` head is not `:scheduled`, so it
  # never blocks probing here.) Promotion itself is the scheduler's job
  # (`promote_probe/2`).
  #
  # The `JOIN LATERAL … LIMIT 1` is an inner join, so an entity with NO transport/
  # response `Log` row is excluded — a manual `suspend` on a quiet entity is inert
  # here (no window to probe), recovered by the operator, not the probe. Derived
  # suspension can't hit this (a tripped entity has failures in the `Log`). See §8.
  # sobelow_skip ["SQL.Query"]
  defp pick_suspended(scope, m) do
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
      AND NOT EXISTS (
        SELECT 1 FROM #{ed_table()} s
        WHERE s.#{scope.id_column} = e.id AND s.state = 'scheduled'
      )
    ORDER BY ll.last_log_id ASC
    LIMIT $1
    """

    %{rows: rows} = query!(sql, [m])
    Enum.map(rows, fn [id] -> id end)
  end

  # ── Age-based give-up (opt-in `:expired`) ────────────────────────────────────

  @doc """
  Opt-in give-up policy: take any still-retrying `:failed` delivery whose age (from
  `created_at`) exceeds `Supervisor.max_delivery_age_ms/0` terminal — set
  `terminal_reason: :expired`, so it stops retrying and its lane is blocked like any
  terminal head. No-op unless the age is configured (`nil` = never expire, the safe
  default). Idempotent (matches only `terminal_reason IS NULL`) and safe on every node.
  """
  def sweep_expired do
    case Stage.max_delivery_age_ms() do
      nil -> :ok
      age_ms when is_integer(age_ms) and age_ms > 0 -> expire_older_than(age_ms)
    end
  end

  # One bulk `:expire` through Ash (not raw SQL) so `updated_at` bumps and host
  # notifiers see the transition. The query-side guard (`state == :failed`,
  # `terminal_reason IS NULL`) is the action's precondition, pushed here the same
  # way the scheduler pushes its promotion guards; `SetAttribute` is
  # atomic-capable, so `:atomic` runs this as a single UPDATE.
  defp expire_older_than(age_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)

    result =
      AshIntegration.event_delivery_resource()
      |> Ash.Query.filter(state == :failed and is_nil(terminal_reason) and created_at < ^cutoff)
      |> Ash.bulk_update(:expire, %{},
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
          Logger.error("Outbound delivery: expiry sweep failed: #{inspect(errors)}")
          0
      end

    if n > 0 do
      Logger.warning(
        "Outbound delivery: expired #{n} delivery(ies) still retrying after " <>
          "#{age_ms}ms — terminal (`:expired`), lanes blocked (no auto-resolve)."
      )

      :telemetry.execute([:ash_integration, :delivery, :expired], %{count: n}, %{
        max_delivery_age_ms: age_ms
      })
    end

    :ok
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
