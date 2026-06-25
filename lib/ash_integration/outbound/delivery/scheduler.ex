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

  @doc """
  Recovery probe: promote **one schedulable head** for one suspended entity
  (`:connection` or `:subscription`), so the relay can observe whether the endpoint
  recovered. The same `schedulable_heads/1` query as the sweep — only this scope's
  suspension is relaxed for `id`; every other gate (lane head / parked-head
  blocking, slot-free, high-water, **the other scope's** suspension) still
  holds, so a probe can never deliver out of order or to a row the other scope has
  halted. Forces a real `:schedule` (never a content-suppression) so the probe
  actually exercises the transport. Returns `:scheduled` or `:none`.

  Which head: the entity's lanes are probed **round-robin, least-recently-probed
  first** (`rotate_lanes/2`), not strict-oldest — otherwise a deterministically
  failing oldest lane monopolises the one probe slot and starves the entity's
  other lanes, holding it suspended even after recovery. See that function.
  """
  def promote_probe(scope, id) when scope in [:connection, :subscription] do
    heads =
      scope
      |> probe_suspension(id)
      |> schedulable_heads()
      |> rotate_lanes(scope)
      |> limit(1)
      |> run_heads()

    case heads do
      [head_id] -> force_schedule(head_id)
      [] -> :none
    end
  end

  # Rotate the single probe across the suspended entity's lanes instead of always
  # taking its strict-oldest head. The starvation it fixes: a non-poison head that
  # deterministically fails (e.g. a per-payload response rejection) and is the
  # entity's oldest is re-promoted every pass — its failure resets without the lane
  # advancing — so it monopolises the one probe slot and the entity's *other* lanes
  # never get a turn. The endpoint can be healthy and a sibling lane's probe would
  # succeed and clear the suspension, but it is never tried, so the entity stays
  # suspended (and all its lanes frozen) indefinitely.
  #
  # Order the candidate lane heads by each lane's **most recent probe** — the max
  # `Log` id for that `(entity, event_key)` over the same per-scope window the
  # entity-level cursor uses (`status = :success OR failure_class = <scope>`). After
  # park a suspended entity has no traffic but its probes, so that row *is* the
  # lane's last probe; no cursor column or process state is needed. Ascending, so
  # the least-recently-probed lane goes first; a lane never probed (no row) sorts
  # first via NULLS FIRST. `event_id` breaks ties and orders the very first pass —
  # so before any lane has been probed this is exactly the old strict-oldest pick.
  #
  # Ordering-safe: cross-lane heads carry distinct `event_key`s, so choosing a
  # different lane never reorders delivery *within* a `(connection_id, event_key)`
  # lane — the shared `schedulable_heads/1` query still hands back each lane's strict
  # head. This is the same `Log`-derived-cursor technique the entity-level
  # round-robin already uses (`Health.pick_suspended/2`), applied one level down.
  defp rotate_lanes(query, scope) do
    query
    |> join(:left_lateral, [head: h], c in subquery(last_lane_probe(scope)),
      on: true,
      as: :lane_cursor
    )
    |> order_by([head: h, lane_cursor: c], asc_nulls_first: c.last_log_id, asc: h.event_id)
  end

  # The lane's most recent probe: the newest `Log` id for this `(entity, event_key)`
  # within the scope's health window. Correlated to the outer `:head` via
  # `parent_as/1` (lateral join), `limit 1` over the recency-ordered window — so at
  # most one row per lane, NULL when the lane has never been probed.
  defp last_lane_probe(scope) do
    {tbl, res} = source(AshIntegration.delivery_log_resource())
    failure_class = probe_failure_class(scope)

    from(l in {tbl, res},
      where: ^lane_cursor_match(scope),
      where: l.status == ^:success or l.failure_class == ^failure_class,
      order_by: [desc: l.id],
      limit: 1,
      select: %{last_log_id: l.id}
    )
  end

  # Same lane key the scheduler orders on `(connection_id, event_key)`, scoped to the
  # probe entity's id column so the cursor counts only this entity's probes.
  defp lane_cursor_match(:connection) do
    dynamic(
      [l],
      l.connection_id == parent_as(:head).connection_id and
        l.event_key == parent_as(:head).event_key
    )
  end

  defp lane_cursor_match(:subscription) do
    dynamic(
      [l],
      l.subscription_id == parent_as(:head).subscription_id and
        l.event_key == parent_as(:head).event_key
    )
  end

  # Each scope's health-window failure class — the `Log` discriminator §5 keys on.
  defp probe_failure_class(:connection), do: :transport
  defp probe_failure_class(:subscription), do: :response

  # Restrict to the probe entity, ignoring ITS OWN suspension but keeping the other
  # scope's. (Not "healthy OR this id" — that would also pull in healthy entities the
  # normal sweep already handles.)
  defp probe_suspension(:connection, id) do
    dynamic([connection: d, subscription: sub], d.id == ^id and sub.suspended == false)
  end

  defp probe_suspension(:subscription, id) do
    dynamic([connection: d, subscription: sub], d.suspended == false and sub.id == ^id)
  end

  # Promote a probe head as a real delivery (bypassing content suppression — a probe
  # must hit the transport to be observed). Still guarded on `state == :pending`.
  defp force_schedule(head_id) do
    case Ash.get(AshIntegration.event_delivery_resource(), head_id, authorize?: false) do
      {:ok, delivery} ->
        if apply_promotion(delivery, :schedule) == :scheduled, do: :scheduled, else: :none

      {:error, _} ->
        :none
    end
  end

  # The single definition of "a legal schedulable lane head", shared by the sweep
  # and the recovery probe (`promote_probe/2`). The ONE thing a caller varies is
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
  #   * high-water gate — `older_undispatched/0`: no OLDER same-key Event is
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
