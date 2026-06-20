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
  require Ash.Expr
  import Ecto.Query

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
    |> Ash.Changeset.filter(Ash.Expr.expr(state == :pending))
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
  # The normal sweep: every ready lane's head, across all NON-suspended
  # connections/subscriptions. Just `schedulable_heads/1` with the "both scopes
  # healthy" suspension predicate — see that function for the shared gates.
  def find_schedulable_events(batch_size) do
    both_healthy()
    |> schedulable_heads()
    |> limit(^batch_size)
    |> run_heads()
  end

  # The single definition of "a legal schedulable lane head", shared by the sweep
  # (and, in a later phase, the recovery probe). The ONE thing a caller varies is
  # the `suspension` predicate; every ordering gate below is fixed, so a second
  # caller can never enforce a different (weaker) set of them:
  #
  #   * lane head — `lane_heads/0` takes `DISTINCT ON (connection_id, event_key)
  #     ORDER BY event_id` (the parent Event's occurrence-ordered UUIDv7; the
  #     delivery's own `id` is dispatch-time, NOT an ordering key), and the outer
  #     `head.state == :pending` drops a lane whose head is `:parked` (a parked
  #     head — even an older one — blocks its lane);
  #   * slot-free — `slot_taken/0`: the lane's one in-flight (`:scheduled`) slot is
  #     not already occupied;
  #   * high-water gate (#56) — `older_undispatched/0`: no OLDER same-key Event is
  #     still undispatched and targeting this connection (an active subscription on
  #     its type/version). Without it a newer event whose delivery already
  #     materialised could be delivered ahead of an older one still fanning out,
  #     leaving the consumer on a stale final state. Gated on *dispatch*, so it only
  #     spans the dispatch window.
  #
  # Blocked lanes never appear, so the sweep loop terminates and parked/suspended
  # lanes don't generate per-pass log noise.
  defp schedulable_heads(suspension) do
    conn_res = AshIntegration.connection_resource()
    sub_res = AshIntegration.subscription_resource()

    from(head in subquery(lane_heads()),
      as: :head,
      join: d in ^conn_res,
      as: :connection,
      on: d.id == head.connection_id,
      join: s in ^sub_res,
      as: :subscription,
      on: s.id == head.subscription_id,
      where: head.state == ^:pending,
      where: ^suspension,
      where: not exists(slot_taken()),
      where: not exists(older_undispatched()),
      select: fragment("?::text", head.id)
    )
  end

  # The normal sweep's suspension predicate: both scopes must be healthy. A probe
  # (later phase) is the same query with this one predicate relaxed for its set.
  defp both_healthy do
    dynamic([connection: d, subscription: sub], d.suspended == false and sub.suspended == false)
  end

  # Each lane's head = the oldest (`pending`/`parked`) row per
  # `(connection_id, event_key)`.
  defp lane_heads do
    {tbl, res} = source(AshIntegration.event_delivery_resource())

    from(e in {tbl, res},
      where: e.state in ^[:pending, :parked],
      distinct: [e.connection_id, e.event_key],
      order_by: [e.connection_id, e.event_key, e.event_id],
      select: %{
        id: e.id,
        connection_id: e.connection_id,
        event_key: e.event_key,
        state: e.state,
        subscription_id: e.subscription_id,
        event_id: e.event_id
      }
    )
  end

  # The lane's single in-flight slot is taken (a `:scheduled` row on it exists).
  defp slot_taken do
    {tbl, res} = source(AshIntegration.event_delivery_resource())

    from(s in {tbl, res},
      where:
        s.connection_id == parent_as(:head).connection_id and
          s.event_key == parent_as(:head).event_key and
          s.state == ^:scheduled
    )
  end

  # An OLDER same-key Event is still undispatched and targets this connection.
  defp older_undispatched do
    {events, events_res} = source(AshIntegration.event_resource())
    sub_res = AshIntegration.subscription_resource()

    from(ev in {events, events_res},
      join: s2 in ^sub_res,
      on:
        s2.connection_id == parent_as(:head).connection_id and
          s2.event_type == ev.event_type and
          s2.version == ev.version and
          s2.active == true,
      where:
        ev.event_key == parent_as(:head).event_key and
          ev.id < parent_as(:head).event_id and
          is_nil(ev.dispatched_at)
    )
  end

  defp run_heads(query) do
    AshIntegration.repo().all(query, log: AshIntegration.query_log_level())
  rescue
    e ->
      Logger.error("Scheduler: find_schedulable_events failed: #{Exception.message(e)}")
      []
  end

  # `{table, resource}` — the Ecto source for a host-configured Ash resource: the
  # explicit table plus the resource (a valid Ecto schema under AshPostgres) for
  # field typing.
  defp source(resource), do: {AshPostgres.DataLayer.Info.table(resource), resource}
end
