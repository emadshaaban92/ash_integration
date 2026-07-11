defmodule Example.Outbound.EventSchedulerTest do
  @moduledoc """
  Tests for the event-first scheduler's promotion/ordering.

  Ordering is keyed on `(connection_id, event_key)` — at most one in-flight event
  per key across ALL subscriptions of the connection, oldest-first. Derived
  suspension (recompute / park / probe) lives in `Example.Outbound.HealthTest`.
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Scheduler
  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  setup do
    %{connection: create_connection!(create_user!())}
  end

  describe "ordering: one in-flight per (connection, event_key)" do
    test "schedules only the oldest event for a shared key, across subscriptions",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")
      s2 = create_subscription!(dest, "stock.changed")

      e1 = create_event!(s1, event_key: "p1")
      e2 = create_event!(s2, event_key: "p1")

      Scheduler.sweep()

      # Exactly one (the oldest, e1) is scheduled; the sibling on the same lane waits.
      assert reload(e1).state == :scheduled
      assert reload(e2).state == :pending

      # Once the in-flight one leaves the lane, the next is promoted in order.
      deliver!(reload(e1))
      Scheduler.sweep()

      assert reload(e2).state == :scheduled
    end

    test "different event keys are scheduled in parallel", %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      e1 = create_event!(s1, event_key: "p1")
      e2 = create_event!(s1, event_key: "p2")

      Scheduler.sweep()

      assert reload(e1).state == :scheduled
      assert reload(e2).state == :scheduled
    end

    test "a parked oldest event blocks its lane", %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      blocked =
        create_event!(s1, event_key: "p1", state: :parked, delivery: nil, last_error: "boom")

      newer = create_event!(s1, event_key: "p1")

      Scheduler.sweep()

      assert reload(blocked).state == :parked
      assert reload(newer).state == :pending
    end

    test "an older deliverable event is scheduled even when a younger sibling is parked",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      # Older = created first (smaller DB-assigned UUIDv7 id).
      older = create_event!(s1, event_key: "p1")

      younger_parked = create_event!(s1, event_key: "p1", state: :parked, delivery: nil)

      Scheduler.sweep()

      # The parked event is younger, so it is NOT the head — the older deliverable
      # one schedules; the parked one only blocks events that come after it.
      assert reload(older).state == :scheduled
      assert reload(younger_parked).state == :parked
    end

    test "many blocked lanes don't stall the sweep (livelock regression)", %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      # More blocked (parked-head) lanes than one batch (@batch_size = 100), each
      # on its own key. Pre-fix, blocked lanes refilled the candidate batch every
      # pass and the batch-full recursion spun forever; now they're excluded, so
      # the sweep terminates and still makes progress on the one ready lane.
      for i <- 1..101 do
        create_event!(s1, event_key: "blocked-#{i}", state: :parked, delivery: nil)
      end

      deliverable = create_event!(s1, event_key: "ready")

      assert Scheduler.sweep() == :ok
      assert reload(deliverable).state == :scheduled
    end

    test "high-water gate: an older undispatched same-key event blocks a newer delivery",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      # An OLDER same-key event is still in the outbox (dispatched_at IS NULL), and
      # the connection has an active subscription for its type. "Older" = smaller
      # UUIDv7 id, which the DB assigns in insertion order — so seed it FIRST.
      older = seed_undispatched_event!(event_type: "widget.updated", event_key: "p1")

      # …then a newer event's delivery materializes. Ordering is by id (no shared
      # timestamp), so even two events captured back-to-back are unambiguously
      # ordered — the gate holds the newer behind the older (stale final state).
      newer = create_event!(s1, event_key: "p1")

      Scheduler.sweep()
      assert reload(newer).state == :pending

      # Once the older event is dispatched (its outcome — a delivery or a skip — is
      # now known), the gate clears and the newer one schedules.
      mark_dispatched!(older)
      Scheduler.sweep()
      assert reload(newer).state == :scheduled
    end

    test "high-water gate ignores older undispatched events the connection doesn't subscribe to",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      # Older (seeded first → smaller id), same key, but a type this connection has
      # no subscription for → it can never produce a delivery on this lane, so it
      # must NOT block.
      seed_undispatched_event!(event_type: "unsubscribed.type", event_key: "p1")

      newer = create_event!(s1, event_key: "p1")

      Scheduler.sweep()
      assert reload(newer).state == :scheduled
    end

    test "a suspended connection is skipped entirely", %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")
      e1 = create_event!(s1, event_key: "p1")

      Ash.update!(Ash.Changeset.for_update(dest, :suspend, %{}, authorize?: false),
        authorize?: false
      )

      Scheduler.sweep()

      assert reload(e1).state == :pending
    end

    test "a deactivated (but not suspended) connection still drains existing events",
         %{connection: dest} do
      # `active` is soft-delete, not a delivery halt: events created while active
      # keep flowing after deactivation. Only `suspended` parks the lane (§5.6).
      s1 = create_subscription!(dest, "widget.updated")
      e1 = create_event!(s1, event_key: "p1")

      Ash.update!(Ash.Changeset.for_update(dest, :deactivate, %{}, authorize?: false),
        authorize?: false
      )

      Scheduler.sweep()

      assert reload(e1).state == :scheduled
    end

    test "the lane parks when its oldest event is on a suspended subscription",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")
      s2 = create_subscription!(dest, "stock.changed")

      oldest = create_event!(s1, event_key: "p1")
      _newer = create_event!(s2, event_key: "p1")

      Ash.update!(Ash.Changeset.for_update(s1, :suspend, %{}, authorize?: false),
        authorize?: false
      )

      Scheduler.sweep()

      # Oldest (on suspended s1) parks the whole lane — the newer event on the
      # healthy s2 must not jump ahead.
      assert reload(oldest).state == :pending
      assert all_events() |> Enum.all?(&(&1.state == :pending))
    end
  end

  describe "bulk promotion of non-suppressible :pending heads" do
    test "pending heads with no body_hash are bulk-scheduled in one sweep",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      # Non-suppressible heads (body_hash nil — the subscription never opted into
      # suppress_unchanged), each on its own lane so all are schedulable at once.
      heads = for i <- 1..5, do: create_event!(s1, event_key: "bulk-#{i}")
      assert Enum.all?(heads, &is_nil(reload(&1).body_hash))

      Scheduler.sweep()

      assert Enum.all?(heads, &(reload(&1).state == :scheduled))
    end

    test "a mixed batch promotes failed, non-suppressible pending, and suppressible pending heads",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      # 1. A due :failed head → bulk :schedule (retry re-promotion).
      failed = create_event!(s1, event_key: "failed", state: :failed)

      # 2. A :pending head with no body_hash → bulk :schedule.
      plain = create_event!(s1, event_key: "plain")

      # 3. A suppressible :pending head whose body equals its lane's last delivered
      #    body → per-row promote/1 → :suppressed. Seed the :delivered baseline
      #    FIRST (smaller event_id) so it is the lane's last-delivered row.
      _baseline = create_event!(s1, event_key: "sup", state: :delivered, body_hash: "H")
      suppressed = create_event!(s1, event_key: "sup", body_hash: "H")

      # 4. A suppressible :pending head whose body has no matching baseline → per-row
      #    promote/1 → :scheduled (suppression must never withhold a genuine change).
      changed = create_event!(s1, event_key: "changed", body_hash: "X")

      Scheduler.sweep()

      assert reload(failed).state == :scheduled
      assert reload(plain).state == :scheduled
      assert reload(suppressed).state == :suppressed
      assert reload(changed).state == :scheduled
    end
  end

  describe "guarded :pending-head promotion closes the read→write race" do
    test "a head that raced to :scheduled between read and write is skipped",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      raced = create_event!(s1, event_key: "raced")

      # Another node promoted it after this sweep read it eligible. The stale batch's
      # guarded write (`state == :pending`) must now match nothing — a clean no-op,
      # not a second promotion.
      Ash.update!(
        Ash.Changeset.for_update(reload(raced), :schedule, %{}, authorize?: false),
        authorize?: false
      )

      assert reload(raced).state == :scheduled
      assert Scheduler.bulk_schedule_pending([raced.id]) == 0
      assert reload(raced).state == :scheduled
    end

    test "a head that raced to a terminal state between read and write is skipped",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      raced = create_event!(s1, event_key: "raced")

      # Cancelled out from under the sweep (terminal). The write guard's
      # `state == :pending` closes the race — no resurrect.
      Ash.update!(
        Ash.Changeset.for_update(reload(raced), :cancel, %{}, authorize?: false),
        authorize?: false
      )

      assert reload(raced).state == :cancelled
      assert Scheduler.bulk_schedule_pending([raced.id]) == 0
      assert reload(raced).state == :cancelled
    end
  end

  describe "guarded :failed-head promotion replays backoff (multi-node race)" do
    test "does not re-promote a re-failed head whose fresh backoff is still in the future",
         %{connection: dest} do
      s1 = create_subscription!(dest, "widget.updated")

      due = create_event!(s1, event_key: "due", state: :failed)
      future = create_event!(s1, event_key: "future", state: :failed)

      # `future` re-failed with a fresh `next_attempt_at` ahead — the exact race the
      # write-time guard defends: a sweep read it eligible, then another node promoted
      # and the relay re-failed it before this (stale) batch's write lands. Without the
      # `next_attempt_at <= now()` predicate on the write, it would be re-promoted
      # immediately, skipping its new backoff.
      set_next_attempt_at!(future, DateTime.add(DateTime.utc_now(), 3600, :second))

      assert Scheduler.bulk_schedule_failed([due.id, future.id]) == 1

      assert reload(due).state == :scheduled
      assert reload(future).state == :failed, "a fresh backoff must not be skipped"
    end
  end

  # Derived suspension (recompute / park / probe) lives in its own DB-backed suite:
  # `Example.Outbound.HealthTest`. This file stays focused on scheduling/ordering.

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp set_next_attempt_at!(delivery, at) do
    Example.Repo.update_all(
      from(d in "outbound_event_deliveries", where: d.id == type(^delivery.id, Ecto.UUID)),
      set: [next_attempt_at: at]
    )
  end

  defp deliver!(event) do
    Ash.update!(
      Ash.Changeset.for_update(event, :deliver, %{delivery_metadata: %{}}, authorize?: false),
      authorize?: false
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

  defp create_event!(subscription, overrides), do: build_delivery!(subscription, overrides)

  # An Event with no delivery and no `dispatched_at` — still in the outbox, for
  # exercising the high-water gate.
  defp seed_undispatched_event!(opts) do
    AshIntegration.event_resource()
    |> Ash.Changeset.for_create(
      :create,
      %{
        # The UUIDv7 id is DB-generated (occurrence order = insertion order), so a
        # caller that needs this event to be "older" must seed it before the newer
        # one.
        event_type: Keyword.fetch!(opts, :event_type),
        version: Keyword.get(opts, :version, 1),
        event_key: Keyword.fetch!(opts, :event_key),
        source_resource: "widget",
        source_resource_id: "r1",
        source_action: "update",
        data: %{}
        # dispatched_at omitted → NULL
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp mark_dispatched!(event) do
    Ash.update!(
      Ash.Changeset.for_update(
        event,
        :mark_dispatched,
        %{dispatched_at: DateTime.utc_now()},
        authorize?: false
      ),
      authorize?: false
    )
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)

  defp all_events, do: EventDelivery |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)
end
