defmodule Example.Outbound.HealthTest do
  @moduledoc """
  DB-backed coverage for derived suspension (`design/connection-health.md`): the
  recompute trip signal (§5), park-on-suspend (§6), and the bounded recovery probe
  (§7). Suspension is recomputed from the delivery `Log` ("no success among the last
  N transport/response outcomes"); the probe delegates promotion to the scheduler so
  it inherits every ordering gate.
  """
  use Example.DataCase, async: false

  alias AshIntegration.Outbound.Delivery.Health
  alias AshIntegration.Outbound.Delivery.Scheduler
  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage
  alias Example.Outbound.{Connection, Log, Subscription}

  setup do
    %{connection: create_connection!(create_user!())}
  end

  describe "recompute — derived trip signal" do
    test "suspends only after N transport failures; a success clears it", %{connection: dest} do
      with_window(2, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        ev = create_event!(s1, state: :scheduled)

        record_failure!(ev, "transport")
        Health.recompute()
        refute reload(dest).suspended, "1 failure < N=2 must not trip"

        record_failure!(reload(ev), "transport")
        Health.recompute()
        assert reload(dest).suspended, "2 failures >= N=2 trips"
        refute reload(s1).suspended

        # A logged success is what clears it on the next recompute.
        schedule!(reload(ev))
        deliver!(reload(ev))
        Health.recompute()
        refute reload(dest).suspended
      end)
    end

    test "a response rejection scopes to the subscription, not the connection",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        record_failure!(create_event!(s1, state: :scheduled), "response")

        Health.recompute()

        assert reload(s1).suspended
        refute reload(dest).suspended
        assert [%{status: :failed, failure_class: :response}] = logs()
      end)
    end

    test "an unclassified failure defaults to the subscription (narrower blast radius)",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        record_failure!(create_event!(s1, state: :scheduled), nil)

        Health.recompute()

        assert reload(s1).suspended
        refute reload(dest).suspended
      end)
    end

    test "recompute is transition-only — a re-run does not re-stamp suspended_at",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        record_failure!(create_event!(s1, state: :scheduled), "transport")

        Health.recompute()
        first = reload(dest).suspended_at
        assert first

        Health.recompute()
        assert reload(dest).suspended_at == first
      end)
    end
  end

  describe "park on the suspend transition" do
    test "un-leased :scheduled rows revert to pending; a live-leased row drains",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        unleased = create_event!(s1, event_key: "a", state: :scheduled)
        leased = create_event!(s1, event_key: "b", state: :scheduled)
        stamp_claimed!(leased, DateTime.utc_now())

        record_failure!(unleased, "transport")
        Health.recompute()

        assert reload(dest).suspended
        assert reload(unleased).state == :pending, "un-leased row parked back to pending"
        assert reload(leased).state == :scheduled, "live-leased row left to drain"
      end)
    end

    test "a poison lane stays terminal on suspend; the probe recovers via a healthy lane",
         %{connection: dest} do
      # Regression guard: forgiving a poison row on suspend (resetting it to :pending)
      # turns a known-dead head into the oldest schedulable lane head, which the probe
      # promotes first, fails, resets, and re-promotes forever — starving the healthy
      # lane and never recovering. The poison row must stay :scheduled (terminal) so it
      # is never a lane head, leaving the probe to recover via the healthy lane.
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")

        # Poison lane (created first → oldest event_id) and a separate healthy lane.
        poison = create_event!(s1, event_key: "poison", state: :scheduled)
        stamp_attempts!(poison, Stage.max_attempts())
        healthy = create_event!(s1, event_key: "healthy", state: :pending)

        # Trip the connection's suspension off the poison lane's failure.
        record_failure!(poison, "transport")
        Health.recompute()
        assert reload(dest).suspended

        # Park leaves the poison row terminal (NOT forgiven to :pending).
        assert reload(poison).state == :scheduled, "poison row left terminal, lane blocked"

        # The probe skips the slot-blocked poison lane and promotes the healthy head.
        Health.probe()
        assert reload(healthy).state == :scheduled, "probe recovers via the healthy lane"
        assert reload(poison).state == :scheduled, "poison lane untouched by the probe"

        # A success on the probed (healthy) head clears the suspension.
        deliver!(reload(healthy))
        Health.recompute()
        refute reload(dest).suspended
      end)
    end
  end

  describe "bounded probe (§7)" do
    test "promotes one schedulable head for a suspended connection; a success recovers it",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        ev = create_event!(s1, event_key: "p1", state: :scheduled)

        record_failure!(ev, "transport")
        Health.recompute()
        assert reload(dest).suspended
        assert reload(ev).state == :pending, "parked on suspend"

        Health.probe()
        assert reload(ev).state == :scheduled, "probe promoted one head"

        deliver!(reload(ev))
        Health.recompute()
        refute reload(dest).suspended, "observed success clears suspension"
      end)
    end

    test "probe load is bounded by probe_batch across the suspended set", %{connection: dest} do
      with_health([window_attempts: 1, probe_batch: 1], fn ->
        other = create_connection!(create_user!())

        d1 = create_event!(create_subscription!(dest, "widget.updated"), state: :scheduled)
        record_failure!(d1, "transport")
        Health.recompute()

        d2 = create_event!(create_subscription!(other, "widget.updated"), state: :scheduled)
        record_failure!(d2, "transport")
        Health.recompute()

        assert reload(dest).suspended and reload(other).suspended

        Health.probe()

        scheduled = Enum.count([reload(d1), reload(d2)], &(&1.state == :scheduled))
        assert scheduled == 1, "probe_batch=1 promotes exactly one across the suspended set"
      end)
    end

    test "a probe never jumps a parked head (inherits the scheduler's gates)",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")

        # Trip + suspend the connection, then remove that lane so the ONLY remaining
        # work sits behind a parked head.
        trip = create_event!(s1, event_key: "trip", state: :scheduled)
        record_failure!(trip, "transport")
        Health.recompute()
        assert reload(dest).suspended
        cancel!(reload(trip))

        # Lane "p1": a parked head with a younger deliverable behind it.
        parked = create_event!(s1, event_key: "p1", state: :parked, delivery: nil)
        younger = create_event!(s1, event_key: "p1", state: :pending)

        Health.probe()

        assert reload(younger).state == :pending, "must not promote past the parked head"
        assert reload(parked).state == :parked
      end)
    end

    test "a connection probe skips a response-suspended subscription's lane",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")

        trip = create_event!(s1, event_key: "trip", state: :scheduled)
        record_failure!(trip, "transport")
        Health.recompute()
        suspend!(s1)
        assert reload(dest).suspended and reload(s1).suspended
        cancel!(reload(trip))

        pending = create_event!(s1, event_key: "p1", state: :pending)

        Health.probe()

        assert reload(pending).state == :pending,
               "the connection probe must not promote a response-suspended subscription's row"
      end)
    end

    test "a probe respects the high-water gate — no jump past an undispatched older event",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")

        trip = create_event!(s1, event_key: "trip", state: :scheduled)
        record_failure!(trip, "transport")
        Health.recompute()
        assert reload(dest).suspended
        cancel!(reload(trip))

        # An OLDER same-key Event still in the outbox (dispatched_at IS NULL), then a
        # newer event whose delivery materialised on the same lane. The high-water
        # gate holds the newer behind the older until the older dispatches.
        older = seed_undispatched_event!(event_type: "widget.updated", event_key: "p1")
        newer = create_event!(s1, event_key: "p1")

        Health.probe()

        assert reload(newer).state == :pending,
               "must not promote past the undispatched older event"

        # Once the older event dispatches, the gate clears and the probe promotes it.
        mark_dispatched!(older)
        Health.probe()
        assert reload(newer).state == :scheduled
      end)
    end
  end

  describe "probe lane rotation (Log cursor)" do
    test "rotates to a less-recently-probed lane instead of the entity's strict oldest",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")

        # Two lanes for the one suspended subscription. L1 ("a") is the OLDER head and
        # the starvation trigger: a head that deterministically fails on every probe
        # (e.g. a per-payload 4xx) and resets back to :pending — so without rotation it
        # is the oldest schedulable head every pass and is re-selected forever.
        l1 = create_event!(s1, event_key: "a", state: :pending)
        l2 = create_event!(s1, event_key: "b", state: :pending)

        suspend!(s1)

        # L1 has already been probed (its deterministic response failure logged); L2
        # never has. The Log id is the lane cursor `rotate_lanes/2` reads.
        log_attempt!(s1, "a", :failed, :response)

        # The probe must rotate to the least-recently-probed lane (L2), NOT re-pick the
        # older, perpetually-failing L1 — otherwise L2 (whose probe could clear the
        # suspension) is starved and the subscription stays suspended forever.
        assert Scheduler.promote_probe(:subscription, s1.id) == :scheduled
        assert reload(l2).state == :scheduled, "probe rotated to the unprobed lane"

        assert reload(l1).state == :pending,
               "the recently-probed oldest lane is skipped this pass"
      end)
    end

    test "with no prior probes, falls back to the strict-oldest lane (event_id tiebreak)",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        l1 = create_event!(s1, event_key: "a", state: :pending)
        l2 = create_event!(s1, event_key: "b", state: :pending)
        suspend!(s1)

        # No lane has a Log row → the cursors tie on NULL, broken by event_id: the
        # oldest wins, exactly the pre-fix behaviour on the first pass.
        assert Scheduler.promote_probe(:subscription, s1.id) == :scheduled
        assert reload(l1).state == :scheduled, "oldest lane probed first when none probed yet"
        assert reload(l2).state == :pending
      end)
    end

    test "the cursor is scoped per lane — a probe on one lane doesn't reorder the others",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        # Three lanes, oldest→newest: a, b, c. "a" was probed most recently, "b" earlier.
        la = create_event!(s1, event_key: "a", state: :pending)
        lb = create_event!(s1, event_key: "b", state: :pending)
        lc = create_event!(s1, event_key: "c", state: :pending)
        suspend!(s1)

        log_attempt!(s1, "b", :failed, :response)
        log_attempt!(s1, "a", :failed, :response)

        # "c" has no cursor (NULLS FIRST) → it is probed before either already-probed lane.
        assert Scheduler.promote_probe(:subscription, s1.id) == :scheduled
        assert reload(lc).state == :scheduled
        assert reload(la).state == :pending
        assert reload(lb).state == :pending
      end)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp cancel!(event) do
    Ash.update!(Ash.Changeset.for_update(event, :cancel, %{}, authorize?: false),
      authorize?: false
    )
  end

  defp suspend!(record) do
    Ash.update!(Ash.Changeset.for_update(record, :suspend, %{}, authorize?: false),
      authorize?: false
    )
  end

  # An Event with no delivery and no `dispatched_at` — still in the outbox, for the
  # high-water gate. Seed it BEFORE the newer event so its UUIDv7 id is older.
  defp seed_undispatched_event!(opts) do
    AshIntegration.event_resource()
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_type: Keyword.fetch!(opts, :event_type),
        version: Keyword.get(opts, :version, 1),
        event_key: Keyword.fetch!(opts, :event_key),
        source_resource: "widget",
        source_resource_id: "r1",
        source_action: "update",
        data: %{}
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp mark_dispatched!(event) do
    Ash.update!(
      Ash.Changeset.for_update(event, :mark_dispatched, %{dispatched_at: DateTime.utc_now()},
        authorize?: false
      ),
      authorize?: false
    )
  end

  defp with_window(n, fun), do: with_health([window_attempts: n], fun)

  defp with_health(opts, fun) do
    prev = Application.get_env(:ash_integration, :health)
    Application.put_env(:ash_integration, :health, opts)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_integration, :health, prev),
        else: Application.delete_env(:ash_integration, :health)
    end)

    fun.()
  end

  defp record_failure!(event, failure_class) do
    metadata = if failure_class, do: %{"failure_class" => failure_class}, else: %{}

    Ash.update!(
      Ash.Changeset.for_update(
        event,
        :record_attempt_error,
        %{last_error: "boom", delivery_metadata: metadata},
        authorize?: false
      ),
      authorize?: false
    )
  end

  defp schedule!(event) do
    Ash.update!(Ash.Changeset.for_update(event, :schedule, %{}, authorize?: false),
      authorize?: false
    )
  end

  defp deliver!(event) do
    Ash.update!(
      Ash.Changeset.for_update(event, :deliver, %{delivery_metadata: %{}}, authorize?: false),
      authorize?: false
    )
  end

  defp stamp_claimed!(delivery, at) do
    Example.Repo.update_all(
      from(d in "outbound_event_deliveries", where: d.id == type(^delivery.id, Ecto.UUID)),
      set: [claimed_at: at]
    )
  end

  defp stamp_attempts!(delivery, n) do
    Example.Repo.update_all(
      from(d in "outbound_event_deliveries", where: d.id == type(^delivery.id, Ecto.UUID)),
      set: [attempts: n]
    )
  end

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "t-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end

  defp create_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "http://localhost:9999/webhook",
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_subscription!(dest, event_type) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_source: "function transform(event, defaults) return event end"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # A delivery-attempt `Log` row on a lane — the cursor `rotate_lanes/2` reads to tell
  # which lane was probed least recently. Mirrors what a real probe attempt persists
  # (event_key + failure_class), without driving the full relay loop.
  defp log_attempt!(sub, event_key, status, failure_class) do
    Log
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_type: sub.event_type,
        version: sub.version,
        event_key: event_key,
        status: status,
        failure_class: failure_class,
        subscription_id: sub.id,
        connection_id: sub.connection_id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_event!(subscription, overrides), do: build_delivery!(subscription, overrides)

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)

  defp logs, do: Log |> Ash.read!(authorize?: false)
end
