defmodule AshIntegration.Outbound.Delivery.Scheduler do
  @moduledoc """
  GenServer that promotes ready `EventDelivery` heads to `:scheduled` (claimed and
  executed by the delivery relay — `AshIntegration.Outbound.Delivery.Relay`),
  respecting ordering per **`(connection_id, event_key)`** — at most one active head
  per key across ALL subscriptions of the connection, oldest-first. A head is either
  fresh (`:pending`) or a waiting-to-retry `:failed` row being re-promoted; the
  scheduler owns all of "what runs next and when" (lane-head selection, the high-water
  gate, suspension, backoff eligibility, terminal gating).

  The GenServer is an optimization (adaptive: ~1s when busy, 10s idle sweep);
  correctness rests on the partial unique index
  `(connection_id, event_key) WHERE state IN ('scheduled','failed')`, which makes a
  second active head per lane impossible regardless of how many schedulers run — so
  ordering can never be violated even by a mis-built query.

  A lane is left unscheduled when its oldest (`pending`/`parked`/`failed`) head either:

    * is `:parked` — a build-failure awaiting `:reprocess`;
    * is a terminal `:failed` head (`terminal_reason` set) — blocked forever, or a
      `:failed` head still inside its `next_attempt_at` backoff; or
    * belongs to a **suspended** subscription/connection — the ordering guarantee
      forbids delivering a younger event ahead of it (the recovery probe promotes one
      such head at a time — see `Health.probe/0`).

  Connections that are suspended are skipped entirely. All of this is decided in
  a single set-based query (`find_schedulable_events/1`), so blocked lanes are
  simply absent from each pass rather than visited-and-skipped. See
  `design/delivery-retry-model.md`.

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

  # Promote one ready head. A fresh (`:pending`) head is `:suppress`ed when its content
  # is unchanged since the lane's last delivered body, else `:schedule`d; a `:failed`
  # head is a retry re-promotion, always a real `:schedule`. The write is guarded on the
  # row still being in the state the query saw (`apply_promotion/2` pushes `WHERE …
  # state = <that>`), closing the read→write race — a clean no-op, not a resurrect.
  #
  # Deciding suppression HERE is correct and cheap: the lane has no in-flight row
  # (the query required the slot free), so the previous head is already terminal and
  # "the last delivered body" is determinate. A suppressed head never becomes
  # `:scheduled`, so it never enters the delivery relay, never claims a lease, never
  # bumps `attempts`, and never occupies the lane's one in-flight slot.
  defp promote(event_id) do
    case Ash.get(AshIntegration.event_delivery_resource(), event_id, authorize?: false) do
      # A fresh head may be content-suppressed (unchanged body) or scheduled.
      {:ok, %{state: :pending} = delivery} ->
        apply_promotion(delivery, if(suppress?(delivery), do: :suppress, else: :schedule))

      # A `:failed` head is a retry re-promotion — always a real `:schedule` (never
      # content-suppressed: a retry must reach the transport, and suppression only
      # makes sense for a fresh head against its lane's last delivered body).
      {:ok, %{state: :failed} = delivery} ->
        apply_promotion(delivery, :schedule)

      # Raced away since the query (e.g. it advanced to `:parked`): clean no-op.
      {:ok, _delivery} ->
        :skipped

      {:error, _} ->
        :skipped
    end
  end

  # Guarded on the row still being in the state the query saw (`:pending` or `:failed`):
  # the `Ash.Changeset.filter` pushes `WHERE … state = <that>` into the UPDATE, closing
  # the read→write race (coalescing cancelled it, or another scheduler grabbed it) — a
  # clean no-op, not a resurrect. The `{scheduled,failed}` unique index is the hard
  # backstop against two active heads per lane.
  defp apply_promotion(delivery, action) do
    delivery
    |> Ash.Changeset.for_update(action, %{}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(state == ^delivery.state))
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
  Recovery probe: promote the **oldest schedulable head** for one suspended entity
  (`:connection` or `:subscription`), so the relay can observe whether the endpoint
  recovered. The same `schedulable_heads/1` query as the sweep — only this scope's
  suspension is relaxed for `id`; every other gate (lane head / parked-head
  blocking, slot-free, high-water, **the other scope's** suspension) still
  holds, so a probe can never deliver out of order or to a row the other scope has
  halted. Forces a real `:schedule` (never a content-suppression) so the probe
  actually exercises the transport. Returns `:scheduled` or `:none`.
  """
  def promote_probe(scope, id) when scope in [:connection, :subscription] do
    heads =
      scope
      |> probe_suspension(id)
      |> schedulable_heads(false)
      |> order_by([head: h], h.event_id)
      |> limit(1)
      |> run_heads()

    case heads do
      [head_id] -> force_schedule(head_id)
      [] -> :none
    end
  end

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
  #     delivery's own `id` is dispatch-time, NOT an ordering key), and `head_eligible`
  #     drops a lane whose head can't run: a `:parked` head (build failure), a
  #     terminal `:failed` head (`terminal_reason` set — blocks its lane forever), or a
  #     `:failed` head still inside its backoff (`next_attempt_at` in the future). Only
  #     a `:pending` head or a due, non-terminal `:failed` head promotes;
  #   * slot-free — `slot_taken/0`: the lane's in-flight (`:scheduled`) slot is not
  #     already occupied (re-promoting a `:failed` head is fine — it isn't `:scheduled`);
  #   * high-water gate — `older_undispatched/0`: no OLDER same-key Event is
  #     still undispatched and targeting this connection (an active subscription on
  #     its type/version). Without it a newer event whose delivery already
  #     materialised could be delivered ahead of an older one still fanning out,
  #     leaving the consumer on a stale final state. Gated on *dispatch*, so it only
  #     spans the dispatch window.
  #
  # `respect_backoff` gates a `:failed` head on its `next_attempt_at`: the normal sweep
  # honors backoff (`true`); the recovery probe (`false`) ignores it and paces itself.
  #
  # Blocked lanes never appear, so the sweep loop terminates and parked/suspended/
  # backing-off lanes don't generate per-pass log noise. The `{scheduled,failed}`
  # unique index is the hard backstop: even if this query mis-selected, a second active
  # head per lane can't be written.
  defp schedulable_heads(suspension, respect_backoff \\ true) do
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
      where: ^head_eligible(respect_backoff),
      where: ^suspension,
      where: not exists(slot_taken()),
      where: not exists(older_undispatched()),
      select: fragment("?::text", head.id)
    )
  end

  # A lane head may promote iff it is fresh (`:pending`) OR a `:failed` head that is
  # non-terminal and — when `respect_backoff` — past its `next_attempt_at`. A `:parked`
  # head is never eligible (it blocks its lane pending `:reprocess`).
  defp head_eligible(true) do
    dynamic(
      [head: h],
      h.state == ^:pending or
        (h.state == ^:failed and is_nil(h.terminal_reason) and
           (is_nil(h.next_attempt_at) or h.next_attempt_at <= fragment("now()")))
    )
  end

  defp head_eligible(false) do
    dynamic(
      [head: h],
      h.state == ^:pending or (h.state == ^:failed and is_nil(h.terminal_reason))
    )
  end

  # The normal sweep's suspension predicate: both scopes must be healthy. A probe
  # (later phase) is the same query with this one predicate relaxed for its set.
  defp both_healthy do
    dynamic([connection: d, subscription: sub], d.suspended == false and sub.suspended == false)
  end

  # Each lane's head = the oldest (`pending`/`parked`/`failed`) row per
  # `(connection_id, event_key)`. `:failed` is in the pool because a waiting-to-retry
  # or terminal row IS its lane's held head — if it's the oldest, it (re-)promotes or
  # blocks the lane; a younger row must never jump ahead of it. `terminal_reason` and
  # `next_attempt_at` are selected so `schedulable_heads/2` can gate a `:failed` head.
  defp lane_heads do
    {tbl, res} = source(AshIntegration.event_delivery_resource())

    from(e in {tbl, res},
      where: e.state in ^[:pending, :parked, :failed],
      distinct: [e.connection_id, e.event_key],
      order_by: [e.connection_id, e.event_key, e.event_id],
      select: %{
        id: e.id,
        connection_id: e.connection_id,
        event_key: e.event_key,
        state: e.state,
        subscription_id: e.subscription_id,
        event_id: e.event_id,
        terminal_reason: e.terminal_reason,
        next_attempt_at: e.next_attempt_at
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
