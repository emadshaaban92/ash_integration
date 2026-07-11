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
  require Ash.Query
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
    ref = Process.send_after(self(), :schedule, @idle_interval)

    {:ok,
     %{
       last_run_at: System.monotonic_time(:millisecond) - @min_run_interval_ms,
       deferred: false,
       idle_timer: ref
     }}
  end

  @impl true
  def handle_cast(:schedule, state), do: {:noreply, maybe_run(state)}

  @impl true
  def handle_info(:schedule, state), do: {:noreply, maybe_run(state)}

  defp maybe_run(state) do
    now = System.monotonic_time(:millisecond)

    if run_due?(state.last_run_at, now) do
      sweep()
      %{state | last_run_at: now, deferred: false, idle_timer: rearm_idle(state.idle_timer)}
    else
      unless state.deferred do
        Process.send_after(self(), :schedule, @min_run_interval_ms - (now - state.last_run_at))
      end

      %{state | deferred: true}
    end
  end

  # Keep exactly ONE idle-sweep timer in flight. Each due run used to arm a fresh
  # 10s timer without cancelling the previous one, so a busy period of `notify/0`-
  # driven runs left roughly one stray idle timer per run perpetually queued —
  # turning the "10s idle sweep" into a near-continuous one. Cancel the prior timer
  # before arming the next so the idle cadence stays bounded regardless of how many
  # runs fired inside a window.
  defp rearm_idle(ref) do
    if ref, do: Process.cancel_timer(ref)
    Process.send_after(self(), :schedule, @idle_interval)
  end

  @doc false
  def run_due?(last_run_at, now) when is_integer(last_run_at) and is_integer(now) do
    now - last_run_at >= @min_run_interval_ms
  end

  @doc """
  Run one scheduling pass: schedule the head event of every ready
  `(connection_id, event_key)` lane. Public so tests can drive it directly.

  `find_schedulable_events/1` already excludes blocked lanes (parked or
  suspended head, in-flight slot taken), so every head it returns is promotable.
  Heads are promoted in as few round-trips as possible:

    * `:failed` heads (retry re-promotions — always a real `:schedule`, never
      content-suppressed) go through ONE guarded bulk update;
    * `:pending` heads with **no** `body_hash` — their subscription never opted
      into `suppress_unchanged`, the common case — can never be suppressed, so
      they too go through ONE guarded bulk update (a mirror of the `:failed`
      path, replaying the per-row eligibility guard);
    * only `:pending` heads that **carry** a `body_hash` (suppression-eligible)
      keep the per-row `promote/1` path, because each needs its own
      content-suppression decision.

  We loop only while a full batch came back **and** we made progress, so a
  persistent failure can't spin.

  Promoting a head either **schedules** it (a delivery job for the relay) or, when
  the subscription opted into `suppress_unchanged` and the head's body is identical
  to the lane's last delivered body, **suppresses** it (`pending → :suppressed`,
  no delivery — see `promote/1`). A suppressed head frees the lane just like a
  delivered one, so the next head promotes on the following pass.
  """
  def sweep do
    heads = find_schedulable_events(@batch_size)
    {failed, pending} = Enum.split_with(heads, &(&1.state == :failed))
    # A `:pending` head with a `body_hash` MAY be `:suppressed` instead of
    # `:scheduled`, so it needs the per-row decision; one with no `body_hash`
    # never can, so it bulk-schedules like a `:failed` head.
    {suppressible, bulk_pending} = Enum.split_with(pending, &is_binary(&1.body_hash))

    progress =
      bulk_schedule_failed(Enum.map(failed, & &1.id)) +
        bulk_schedule_pending(Enum.map(bulk_pending, & &1.id)) +
        Enum.count(suppressible, &(promote(&1.id) in [:scheduled, :suppressed]))

    if length(heads) >= @batch_size and progress > 0, do: sweep(), else: :ok
  end

  @doc false
  # Re-promote the batch's `:failed` heads (retry re-promotions — always a real
  # `:schedule`, never content-suppressed) in ONE guarded bulk UPDATE instead of a
  # get+update round-trip per head. The query-side guard replays the FULL eligibility
  # the sweep saw — still `:failed`, still non-terminal, AND still past its
  # `next_attempt_at` backoff — so a row that raced away matches nothing: a clean
  # no-op, not a resurrect. The backoff predicate is load-bearing under a multi-node
  # race: between the sweep's read and this write another node can promote the same
  # `:failed` head, the relay can re-fail it, and it lands back `:failed` with a
  # FRESH `next_attempt_at` in the future; without re-checking backoff here this
  # stale batch would re-promote it immediately, skipping the new backoff. (It also
  # covers the row being finalized elsewhere or taken `:expired` by the age sweep.)
  # `:schedule`'s changes (`SetAttribute` + `ClearClaim`) are all atomic-capable, so
  # `:atomic` runs this as a single UPDATE; notifications still fire for host
  # subscribers. Public (`@doc false`) only so the write-time guard is unit-testable.
  def bulk_schedule_failed([]), do: 0

  def bulk_schedule_failed(ids) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(
      id in ^ids and state == :failed and is_nil(terminal_reason) and
        (is_nil(next_attempt_at) or next_attempt_at <= now())
    )
    |> Ash.bulk_update(:schedule, %{},
      strategy: [:atomic, :stream],
      authorize?: false,
      return_records?: true,
      return_errors?: true,
      notify?: true
    )
    |> case do
      %Ash.BulkResult{records: records} when is_list(records) ->
        length(records)

      %Ash.BulkResult{errors: errors} ->
        Logger.error("Scheduler: bulk :failed-head promotion failed: #{inspect(errors)}")
        0
    end
  end

  @doc false
  # Bulk-promote the batch's non-suppressible `:pending` heads (`body_hash IS NULL`
  # — the subscription never opted into `suppress_unchanged`, so there is no per-row
  # content-suppression decision to make) in ONE guarded bulk UPDATE instead of a
  # get(+baseline)+update round-trip per head. The query-side guard replays EXACTLY
  # the eligibility the per-row path enforces (`apply_promotion/2`): still `:pending`
  # AND still non-terminal — so a row that raced away (coalesced, grabbed by another
  # scheduler, taken `:expired` by the age sweep, or advanced to `:parked`) matches
  # nothing: a clean no-op, not a resurrect. The `{scheduled,failed}` partial unique
  # index remains the hard backstop — the batch holds at most one head per lane
  # (`lane_heads` is `DISTINCT ON (connection_id, event_key)`) and every lane's slot
  # was read free, so no two rows here contend for a lane. `:schedule`'s changes
  # (`SetAttribute` + `ClearClaim`) are atomic-capable, so `:atomic` runs this as a
  # single UPDATE; `notify?: true` fires host notifications exactly as the per-row
  # `Ash.update` does. Public (`@doc false`) only so the write-time guard is
  # unit-testable.
  def bulk_schedule_pending([]), do: 0

  def bulk_schedule_pending(ids) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(id in ^ids and state == :pending and is_nil(terminal_reason))
    |> Ash.bulk_update(:schedule, %{},
      strategy: [:atomic, :stream],
      authorize?: false,
      return_records?: true,
      return_errors?: true,
      notify?: true
    )
    |> case do
      %Ash.BulkResult{records: records} when is_list(records) ->
        length(records)

      %Ash.BulkResult{errors: errors} ->
        Logger.error("Scheduler: bulk :pending-head promotion failed: #{inspect(errors)}")
        0
    end
  end

  # Promote one ready `:pending` head: `:suppress`ed when its content is unchanged
  # since the lane's last delivered body, else `:schedule`d. The write is guarded on
  # the row still being in the state the query saw (`apply_promotion/2` pushes
  # `WHERE … state = <that>`), closing the read→write race — a clean no-op, not a
  # resurrect.
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

      # A `:failed` head raced in behind a stale id (normally bulk-promoted above) —
      # a retry re-promotion, always a real `:schedule`. Route it through the SAME
      # backoff-guarded bulk UPDATE as the bulk path (`bulk_schedule_failed/1`) rather
      # than the bare `apply_promotion/2` (which guards only state+terminal): otherwise
      # the multi-node race — another node promotes, the relay re-fails it with a fresh
      # `next_attempt_at`, this stale write lands — would skip the new backoff here too,
      # the very bug the bulk path fixes, ten lines away. (`apply_promotion/2` can't
      # gain the predicate unconditionally: the probe's `force_schedule/1` shares it and
      # deliberately ignores backoff.)
      {:ok, %{state: :failed} = delivery} ->
        if bulk_schedule_failed([delivery.id]) == 1, do: :scheduled, else: :skipped

      # Raced away since the query (e.g. it advanced to `:parked`): clean no-op.
      {:ok, _delivery} ->
        :skipped

      {:error, _} ->
        :skipped
    end
  end

  # Guarded on the row still being in the state the query saw (`:pending` or `:failed`)
  # AND still non-terminal: the `Ash.Changeset.filter` pushes `WHERE … state = <that>
  # AND terminal_reason IS NULL` into the UPDATE, closing the read→write race
  # (coalescing cancelled it, another scheduler grabbed it, or the age sweep took it
  # `:expired` after the query saw it eligible) — a clean no-op, not a resurrect. The
  # `{scheduled,failed}` unique index is the hard backstop against two active heads
  # per lane.
  defp apply_promotion(delivery, action) do
    delivery
    |> Ash.Changeset.for_update(action, %{}, authorize?: false)
    |> Ash.Changeset.filter(Ash.Expr.expr(state == ^delivery.state and is_nil(terminal_reason)))
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
      [head] -> force_schedule(head.id)
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
  # must hit the transport to be observed). Still guarded on the state the read saw
  # (`:pending` or a non-terminal `:failed`) via `apply_promotion/2`.
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
      # `state` and `body_hash` ride along so the sweep can split heads without a
      # re-read: `:failed` (bulk-promoted) from `:pending`, and within `:pending`
      # the non-suppressible ones (`body_hash IS NULL` — also bulk-promoted) from
      # the suppression-eligible ones (per-row decision).
      select: %{
        id: fragment("?::text", head.id),
        state: head.state,
        body_hash: head.body_hash
      }
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
  # `next_attempt_at` are selected so `schedulable_heads/2` can gate a `:failed` head;
  # `body_hash` so it can split suppression-eligible `:pending` heads from the rest.
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
        next_attempt_at: e.next_attempt_at,
        body_hash: e.body_hash
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
