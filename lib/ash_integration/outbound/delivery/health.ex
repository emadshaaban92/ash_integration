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

    # `recompute/0` and `probe/0` are also called directly (tests, manual runs) and
    # re-read these knobs off-process, so publish the merged values (start_link opts
    # over app env) to `:persistent_term` for lock-free reads — mirroring how
    # `Retention` threads its window knobs. Without this, start_link opts for
    # `window_attempts`/`probe_batch` were silently dropped (only the intervals were
    # kept), so tests configuring them via start_link had no effect.
    put_config(:window_attempts, config[:window_attempts])
    put_config(:probe_batch, config[:probe_batch])

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

  @impl true
  def terminate(_reason, _state) do
    # Erase the published knobs so a stopped GenServer leaves no stale values in the
    # global `:persistent_term` for later direct `recompute/0`/`probe/0` calls in the
    # same VM — a cross-test-contamination footgun the `Application.put_env`-based
    # config didn't have (`get_config/1` prefers a published value unconditionally).
    # Harmless on the app's own shutdown; a crash-restart re-publishes in `init/1`.
    :persistent_term.erase({__MODULE__, :window_attempts})
    :persistent_term.erase({__MODULE__, :probe_batch})
    :ok
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
    |> Ash.Changeset.for_update(:suspend, %{reason: reason, source: :auto}, authorize?: false)
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

  # Only ever unwind an AUTO (derived-health) suspension. A `:manual` operator pause
  # or a `:parked` opt-in suspend has its own origin and recovery path — the recompute
  # must not silently resume it just because the entity's frozen `Log` window happens
  # to contain a success (a manually-paused-but-healthy connection; a parked-suspended
  # subscription whose earlier lanes delivered fine). The source guard is what keeps
  # those distinct suspensions from flapping. See `design/connection-health.md` §8 and
  # the ParkedHealth "distinct suspension" note.
  #
  # `is_nil(suspension_source)` counts as `:auto`: a suspension that predates the
  # `suspension_source` column (every in-flight suspension on upgrade day) carries
  # `NULL`, and before this column recompute unwound ALL of them — so treating legacy
  # `NULL` as auto-unwindable preserves the pre-upgrade recovery guarantee (and is
  # self-healing: every new suspension records a real source). Mirrors the probe's
  # `coalesce(suspension_source, 'auto')` candidate filter.
  defp unsuspend(scope, id) do
    scope.resource
    |> Ash.get!(id, authorize?: false)
    |> Ash.Changeset.for_update(:unsuspend, %{}, authorize?: false)
    |> Ash.Changeset.filter(
      Ash.Expr.expr(
        suspended == true and (is_nil(suspension_source) or suspension_source == :auto)
      )
    )
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
  # by each one's most recent probe-relevant `Log` row, skipping any that still hold
  # an in-flight `:scheduled` delivery so a probe is never stacked. (A suspended
  # entity's other heads sit in `:failed`, promoted only by the probe; a terminal
  # `:failed` head is not `:scheduled`, so it never blocks probing here.) Promotion
  # itself is the scheduler's job (`promote_probe/2`).
  #
  # The cursor's match set is `status = 'success' OR failure_class IN
  # ('<scope class>', 'probe')`. A FAILED probe is logged `failure_class: 'probe'`
  # (relay.ex — a suspended entity's retryable failure is probe-paced, out of the
  # health windows), NOT the scope class, so it must be counted here or the cursor
  # would never advance on a failing probe: with more suspended entities than
  # `probe_batch` and fast-failing endpoints the same batch would be re-probed every
  # tick and the rest NEVER probed — stuck suspended even after recovery. Including
  # `'probe'` makes each failing probe advance the entity to the back of the rotation.
  #
  # The `LEFT JOIN LATERAL` (was an inner join) keeps an entity with NO matching
  # `Log` row in the set, ordered FIRST (`NULLS FIRST`) as the most-starved. This
  # matters after retention: `Retention` trims `Log` rows older than `delivery_days`
  # with no status filter, so an entity suspended longer than that window loses its
  # last anchor row; an inner join would drop it from the probe (and it is also
  # absent from `recompute`'s candidate set) — stuck suspended forever with zero
  # signal. With the left join it stays probeable, and the first failing probe writes
  # a fresh `'probe'` anchor. (`e.id` breaks ties so anchorless entities still rotate
  # deterministically.)
  #
  # The candidate set is restricted to `:auto` (derived-health) suspensions — the ONLY
  # kind this probe/recompute cycle can recover. This is load-bearing given the left
  # join: a `:manual` operator pause or a `:parked` opt-in suspend is anchorless
  # (quiet, or a backlog of unpromotable `:parked` heads), so its `NULL` cursor would
  # pin it to the FRONT of the `NULLS FIRST` rotation forever — with ≥ `probe_batch`
  # such entities the batch is all unpromotable and genuinely-recovering `:auto`
  # suspensions would never be probed again, re-creating the very starvation this file
  # set out to kill. Restricting to `:auto` also stops the probe from pushing a REAL
  # delivery through an operator-paused (`:manual`) endpoint, and from burning a slot
  # on a `:parked` subscription that `recompute` will never auto-resume anyway (bug 2).
  # `coalesce(…, 'auto')` treats a legacy `NULL` (a suspension that predates the
  # `suspension_source` column) as `:auto`, matching the unsuspend guard.
  # sobelow_skip ["SQL.Query"]
  defp pick_suspended(scope, m) do
    sql = """
    SELECT e.id::text
    FROM #{table(scope.resource)} e
    LEFT JOIN LATERAL (
      SELECT l.id AS last_log_id
      FROM #{log_table()} l
      WHERE l.#{scope.id_column} = e.id
        AND (l.status = 'success' OR l.failure_class IN ('#{scope.failure_class}', 'probe'))
      ORDER BY l.id DESC
      LIMIT 1
    ) ll ON true
    WHERE e.suspended = true
      AND coalesce(e.suspension_source, 'auto') = 'auto'
      AND NOT EXISTS (
        SELECT 1 FROM #{ed_table()} s
        WHERE s.#{scope.id_column} = e.id AND s.state = 'scheduled'
      )
    ORDER BY ll.last_log_id ASC NULLS FIRST, e.id ASC
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

  def window_attempts, do: get_config(:window_attempts)
  defp probe_batch, do: get_config(:probe_batch)

  # Prefer the value the running GenServer published (start_link opts merged over app
  # env); fall back to the app-env config when no GenServer is running (direct
  # `recompute/0`/`probe/0` calls in tests/manual runs). This keeps both the
  # start_link path and the `Application.put_env` path effective. Note the precedence
  # inversion vs. the old app-env-only reader: once a GenServer has published (and
  # until it terminates, which erases the keys), a runtime `Application.put_env` is
  # ignored — a consistent snapshot rather than a mid-run-mutable read.
  defp get_config(key) do
    case :persistent_term.get({__MODULE__, key}, :__unset__) do
      :__unset__ -> Keyword.fetch!(config(), key)
      value -> value
    end
  end

  # Guarded put so a restart with unchanged config triggers no persistent_term
  # global heap-scan (same pattern as `Retention.put_config/2`).
  defp put_config(key, value) do
    pt_key = {__MODULE__, key}

    case :persistent_term.get(pt_key, :__unset__) do
      ^value -> :ok
      _ -> :persistent_term.put(pt_key, value)
    end
  end

  defp config, do: validate!(Application.get_env(:ash_integration, :health, []))

  defp log_table, do: table(AshIntegration.delivery_log_resource())
  defp ed_table, do: table(AshIntegration.event_delivery_resource())
  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp query!(sql, params) do
    AshIntegration.repo().query!(sql, params, log: AshIntegration.query_log_level())
  end
end
