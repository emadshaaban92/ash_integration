defmodule AshIntegration.Outbound.Delivery.Scheduler do
  @moduledoc """
  GenServer that promotes `pending` outbound events to `scheduled` (claimed and
  executed by the delivery relay — `AshIntegration.Outbound.Delivery.Relay`),
  respecting ordering per **`(connection_id, event_key)`** — at most one in-flight
  event per key across ALL subscriptions of the connection, oldest-first.

  The GenServer is an optimization (adaptive: ~1s when busy, 10s idle sweep);
  correctness rests on the partial unique index
  `(connection_id, event_key) WHERE state = 'scheduled'`, which makes
  double-scheduling impossible regardless of how many schedulers run.

  A lane is parked (left unscheduled) when its oldest (`pending`/`parked`) event
  either:

    * is in the `:parked` state — a build-failure awaiting `:reprocess`; or
    * belongs to a **suspended subscription** — the ordering guarantee forbids
      delivering a younger event ahead of it.

  Connections that are suspended are skipped entirely. All of this is decided in
  a single set-based query (`find_schedulable_events/1`), so blocked lanes are
  simply absent from each pass rather than visited-and-skipped.
  """
  use GenServer

  require Logger
  require Ash.Query
  import Ash.Expr

  @idle_interval :timer.seconds(10)
  @min_run_interval_ms 1_000
  @batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Notify the scheduler that new events may be ready. Fire-and-forget; if the
  process is down the 10s self-timer catches up. Do NOT change to `call`.
  """
  def notify, do: GenServer.cast(__MODULE__, :schedule)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :schedule, @idle_interval)

    {:ok,
     %{last_run_at: System.monotonic_time(:millisecond) - @min_run_interval_ms, deferred: false}}
  end

  @impl true
  def handle_cast(:schedule, state), do: {:noreply, maybe_run(state)}

  @impl true
  def handle_info(:schedule, state), do: {:noreply, maybe_run(state)}

  defp maybe_run(state) do
    now = System.monotonic_time(:millisecond)

    if run_due?(state.last_run_at, now) do
      sweep()
      Process.send_after(self(), :schedule, @idle_interval)
      %{state | last_run_at: now, deferred: false}
    else
      unless state.deferred do
        Process.send_after(self(), :schedule, @min_run_interval_ms - (now - state.last_run_at))
      end

      %{state | deferred: true}
    end
  end

  @doc false
  def run_due?(last_run_at, now) when is_integer(last_run_at) and is_integer(now) do
    now - last_run_at >= @min_run_interval_ms
  end

  @doc """
  Run one scheduling pass: schedule the head event of every ready
  `(connection_id, event_key)` lane. Public so tests can drive it directly.

  `find_schedulable_events/1` already excludes blocked lanes (parked or
  suspended head, in-flight slot taken), so every id it returns is deliverable.
  We loop only while a full batch came back **and** we made progress, so a
  persistent schedule failure can't spin.
  """
  def sweep do
    ids = find_schedulable_events(@batch_size)
    scheduled = Enum.count(ids, &(schedule_event(&1) == :scheduled))

    if length(ids) >= @batch_size and scheduled > 0, do: sweep(), else: :ok
  end

  # Promote one event `pending → scheduled`, guarded on it still being `:pending`
  # (the `Ash.Changeset.filter` pushes `WHERE … state = 'pending'` into the
  # UPDATE). That closes the read→write race: between the query above and here,
  # coalescing may have cancelled it or another scheduler may have grabbed it — a
  # clean no-op either way, not a resurrect.
  # The partial unique index is the backstop against two in-flight per lane.
  defp schedule_event(event_id) do
    case Ash.get(AshIntegration.event_delivery_resource(), event_id, authorize?: false) do
      {:ok, event} ->
        event
        |> Ash.Changeset.for_update(:schedule, %{}, authorize?: false)
        |> Ash.Changeset.filter(expr(state == :pending))
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _} -> :scheduled
          {:error, _} -> :skipped
        end

      {:error, _} ->
        :skipped
    end
  end

  @doc false
  # One set-based query returns the **event id to schedule** for every ready lane:
  #
  #   * `DISTINCT ON (connection_id, event_key) … ORDER BY event_id` picks each
  #     lane's head — the oldest event in the `pending`/`parked` frontier. We
  #     order by the parent Event's UUIDv7 (`event_id`), which is occurrence-
  #     ordered; the delivery's own `id` is dispatch-time, so it is NOT a valid
  #     ordering key;
  #   * `head.state = 'pending'` keeps only lanes whose head is deliverable (a
  #     `parked` head — even an *older* one — blocks the lane and is excluded);
  #   * `sub.suspended = false` / `d.suspended = false` exclude suspended heads /
  #     connections;
  #   * `NOT EXISTS (… 'scheduled')` excludes lanes whose one in-flight slot is
  #     taken (this is a *slot-free* check, independent of the head — keep it).
  #
  # Blocked lanes never appear, so the sweep loop terminates and parked/suspended
  # lanes don't generate per-pass log noise.
  def find_schedulable_events(batch_size) do
    repo = AshIntegration.repo()
    event_table = AshPostgres.DataLayer.Info.table(AshIntegration.event_delivery_resource())
    events_table = AshPostgres.DataLayer.Info.table(AshIntegration.event_resource())
    connection_table = AshPostgres.DataLayer.Info.table(AshIntegration.connection_resource())
    subscription_table = AshPostgres.DataLayer.Info.table(AshIntegration.subscription_resource())

    # The final `NOT EXISTS` is the high-water gate: don't schedule a lane's head
    # while an OLDER same-`event_key` Event is still undispatched (`dispatched_at IS
    # NULL`) and would target this connection (an active subscription on its
    # type/version). Without it, a newer event whose delivery already materialized
    # could be scheduled and delivered before an older one finishes fanning out —
    # leaving the consumer on a stale final state (bug #56). We gate on *dispatch*
    # (not delivery): once the older event is dispatched, its outcome (a delivery,
    # or a `project` skip) is known, so blocking only spans the dispatch window.
    query = """
    SELECT head.id::text
    FROM (
      SELECT DISTINCT ON (e.connection_id, e.event_key)
             e.id, e.connection_id, e.event_key, e.state, e.subscription_id, e.event_id
      FROM #{event_table} e
      WHERE e.state IN ('pending', 'parked')
      ORDER BY e.connection_id, e.event_key, e.event_id ASC
    ) head
    JOIN #{connection_table} d ON d.id = head.connection_id
    JOIN #{subscription_table} sub ON sub.id = head.subscription_id
    WHERE head.state = 'pending'
      AND d.suspended = false
      AND sub.suspended = false
      AND NOT EXISTS (
        SELECT 1 FROM #{event_table} s
        WHERE s.connection_id = head.connection_id
          AND s.event_key = head.event_key
          AND s.state = 'scheduled'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM #{events_table} ev
        JOIN #{subscription_table} s2
          ON s2.connection_id = head.connection_id
         AND s2.event_type = ev.event_type
         AND s2.version = ev.version
         AND s2.active = true
        WHERE ev.event_key = head.event_key
          AND ev.id < head.event_id
          AND ev.dispatched_at IS NULL
      )
    LIMIT $1
    """

    case repo.query(query, [batch_size]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id] -> id end)

      {:error, error} ->
        Logger.error("Scheduler: find_schedulable_events failed: #{inspect(error)}")
        []
    end
  end
end
