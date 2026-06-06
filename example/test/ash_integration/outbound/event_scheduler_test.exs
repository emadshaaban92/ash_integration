defmodule Example.Outbound.EventSchedulerTest do
  @moduledoc """
  Tests for the event-first scheduler + two-level suspension (Task 4).

  Ordering is keyed on `(connection_id, event_key)` — at most one in-flight
  event per key across ALL subscriptions of the connection, oldest-first — and
  suspension is two-level: response rejections suspend the subscription, transport
  failures suspend the connection, and a successful delivery resets both.
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Scheduler
  alias Example.Outbound.{Connection, Log, EventDelivery, Subscription}

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
      # ordered — the gate holds the newer behind the older (stale final state, #56).
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

  describe "two-level suspension" do
    test "a response rejection bumps + auto-suspends the SUBSCRIPTION, not the connection",
         %{connection: dest} do
      with_threshold(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        event = create_event!(s1, state: :scheduled)

        record_failure!(event, "response")

        assert reload(s1).consecutive_failures == 1
        assert reload(s1).suspended
        assert reload(dest).consecutive_failures == 0
        refute reload(dest).suspended
        assert [%{status: :failed}] = logs()
      end)
    end

    test "a transport failure bumps + auto-suspends the DESTINATION, not the subscription",
         %{connection: dest} do
      with_threshold(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        event = create_event!(s1, state: :scheduled)

        record_failure!(event, "transport")

        assert reload(dest).consecutive_failures == 1
        assert reload(dest).suspended
        assert reload(s1).consecutive_failures == 0
        refute reload(s1).suspended
      end)
    end

    test "an unclassified failure defaults to the subscription (narrower blast radius)",
         %{connection: dest} do
      with_threshold(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        event = create_event!(s1, state: :scheduled)

        record_failure!(event, nil)

        assert reload(s1).suspended
        refute reload(dest).suspended
      end)
    end

    test "a successful delivery resets both counters", %{connection: dest} do
      # Default (high) threshold so the failures bump counters without suspending.
      s1 = create_subscription!(dest, "widget.updated")
      event = create_event!(s1, state: :scheduled)

      record_failure!(event, "response")
      record_failure!(reload(event), "transport")

      assert reload(s1).consecutive_failures == 1
      assert reload(dest).consecutive_failures == 1

      deliver!(reload(event))

      assert reload(s1).consecutive_failures == 0
      assert reload(dest).consecutive_failures == 0
      assert reload(event).state == :delivered
      assert Enum.any?(logs(), &(&1.status == :success))
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp with_threshold(n, fun) do
    prev = Application.get_env(:ash_integration, :auto_suspension_threshold)
    Application.put_env(:ash_integration, :auto_suspension_threshold, n)
    on_exit(fn -> Application.put_env(:ash_integration, :auto_suspension_threshold, prev) end)
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
        transform_source: "result = event"
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

  defp logs, do: Log |> Ash.read!(authorize?: false)
end
