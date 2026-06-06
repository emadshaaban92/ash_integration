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

  **Content suppression** is decided here too (`suppress_unchanged`): when a ready
  head's body is identical to its lane's last delivered body, it is promoted
  `pending → :suppressed` instead of `:scheduled` — so an unchanged state never
  becomes a delivery, never reaches the relay, and never occupies the lane's
  in-flight slot. This is the natural place for it: the slot is free, so the prior
  head is terminal and "the last delivered body" is already known.
  """
  use GenServer

  require Logger
  import Ash.Expr

  alias AshIntegration.Outbound.Delivery.Dedup

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
  suspended head, in-flight slot taken), so every id it returns is promotable.
  We loop only while a full batch came back **and** we made progress, so a
  persistent failure can't spin.

  Promoting a head either **schedules** it (a delivery job for the relay) or, when
  the subscription opted into `suppress_unchanged` and the head's body is identical
  to the lane's last delivered body, **suppresses** it (`pending → :suppressed`,
  no delivery — see `promote/1`). A suppressed head frees the lane just like a
  delivered one, so the next head promotes on the following pass.
  """
  def sweep do
    ids = find_schedulable_events(@batch_size)
    progress = Enum.count(ids, &(promote(&1) in [:scheduled, :suppressed]))

    if length(ids) >= @batch_size and progress > 0, do: sweep(), else: :ok
  end

  # Promote one ready head: `:suppress` it when its content is unchanged since the
  # lane's last delivered body, otherwise `:schedule` it. Both are guarded on the
  # row still being `:pending` (the `Ash.Changeset.filter` pushes `WHERE … state =
  # 'pending'` into the UPDATE) — closing the read→write race: between the query
  # above and here, coalescing may have cancelled it or another scheduler may have
  # grabbed it, a clean no-op either way, not a resurrect. The partial unique index
  # is the backstop against two in-flight per lane.
  #
  # Deciding suppression HERE is correct and cheap: the lane has no in-flight row
  # (the query required the slot free), so the previous head is already terminal and
  # "the last delivered body" is determinate. A suppressed head never becomes
  # `:scheduled`, so it never enters the delivery relay, never claims a lease, never
  # bumps `attempts`, and never occupies the lane's one in-flight slot.
  defp promote(event_id) do
    case Ash.get(AshIntegration.event_delivery_resource(), event_id, authorize?: false) do
      {:ok, delivery} ->
        apply_promotion(delivery, if(suppress?(delivery), do: :suppress, else: :schedule))

      {:error, _} ->
        :skipped
    end
  end

  defp apply_promotion(delivery, action) do
    delivery
    |> Ash.Changeset.for_update(action, %{}, authorize?: false)
    |> Ash.Changeset.filter(expr(state == :pending))
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> promoted_result(action)
      {:error, _} -> :skipped
    end
  end

  defp promoted_result(:suppress), do: :suppressed
  defp promoted_result(:schedule), do: :scheduled

  # A row carries a `body_hash` only when its subscription opted into
  # `suppress_unchanged` (the Resolver computes it for those alone), so the column's
  # presence scopes the check. Suppress iff that hash equals the lane's last
  # delivered body. Any lookup error falls back to "don't suppress" (schedule) —
  # suppression must never cause a missed delivery.
  defp suppress?(%{body_hash: hash} = delivery) when is_binary(hash) do
    Dedup.last_delivered_hash(delivery) == hash
  rescue
    e ->
      # Fail open: a baseline-lookup fault must never block a delivery. But log it —
      # a persistent fault would otherwise silently disable suppression with no
      # signal at all.
      Logger.warning(
        "Scheduler: suppression baseline lookup failed for delivery #{delivery.id} " <>
          "(subscription #{delivery.subscription_id}, key #{delivery.event_key}); " <>
          "scheduling normally. #{Exception.message(e)}"
      )

      false
  end

  defp suppress?(_delivery), do: false

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

    case repo.query(query, [batch_size], log: AshIntegration.query_log_level()) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id] -> id end)

      {:error, error} ->
        Logger.error("Scheduler: find_schedulable_events failed: #{inspect(error)}")
        []
    end
  end
end
