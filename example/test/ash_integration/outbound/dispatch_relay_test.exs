defmodule Example.Outbound.DispatchRelayTest do
  @moduledoc """
  Tests for the outbox **dispatch relay** (outbound-architecture.md §6, #79).

  Capture writes only undispatched `Event` rows; the relay claims them and fans
  them out. Prep (`project` + transform) runs in the Broadway processor stage
  (`prepare_messages`/`handle_message`); the `:dispatch` action then stamps
  `dispatched_at` AND materializes deliveries + coalesces in ONE transaction
  (`handle_batch`). We cover:

    * the outbox contract (capture enqueues no job; Events start undispatched);
    * the in-process drain (real relay callbacks) materializing + stamping;
    * **batched `project`** — one call per (type, version);
    * the #79 invariant — a bad transform parks only its own delivery, never the
      batch, and never a sibling subscription;
    * atomicity — a failed materialize rolls the whole event back (nothing stamped);
    * claim semantics, terminal (poison) events (#60);
    * the Broadway glue (`prepare_messages`/`handle_message`/`handle_batch`/ack);
    * the real async pipeline over an isolated `start_supervised!` instance.
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias AshIntegration.Outbound.Dispatch.Acknowledger
  alias AshIntegration.Outbound.Dispatch.Relay
  alias AshIntegration.Outbound.Dispatch.Dispatcher
  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, Event, EventDelivery, ProjectProbe, Subscription}

  setup do
    owner = create_user!()
    %{owner: owner, connection: create_connection!(owner)}
  end

  describe "the outbox contract (capture)" do
    test "capture writes an undispatched Event and enqueues no dispatch job", %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})

      [event] = Ash.read!(Event, authorize?: false)
      assert is_nil(event.dispatched_at)
      assert is_nil(event.claimed_at)
      assert event.dispatch_attempts == 0
      assert is_nil(event.dispatch_error)

      assert Ash.count!(EventDelivery, authorize?: false) == 0
    end
  end

  describe "drain (real relay callbacks, in-process)" do
    test "fans out undispatched events and stamps dispatched_at atomically", %{connection: conn} do
      s1 = create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})

      drain_dispatch!()

      assert [delivery] = events_for(s1)
      assert delivery.state == :pending
      assert [event] = Ash.read!(Event, authorize?: false)
      refute is_nil(event.dispatched_at)
      assert event.dispatch_attempts == 1
    end

    test "is a no-op once the outbox is drained", %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})

      drain_dispatch!()
      # Drained: dispatched events are never re-claimed, no duplicate deliveries.
      drain_dispatch!()
      assert Ash.count!(EventDelivery, authorize?: false) == 1
    end
  end

  describe "batched project (open #2)" do
    setup do
      start_supervised!(ProjectProbe)
      :ok
    end

    test "project runs once per (type, version) over all pending events", %{connection: conn} do
      create_subscription!(conn, "test.batched")

      for _ <- 1..3, do: create_widget!(%{name: "w", stock: 1})
      assert Ash.count!(Event, authorize?: false) == 3

      drain_dispatch!()

      # The processor `{type, version}` partition groups all three onto one
      # prepare_messages call → a single `project` invocation with the whole batch.
      assert ProjectProbe.batches() == [3]
      assert Ash.count!(EventDelivery, authorize?: false) == 3
    end
  end

  describe "#79 invariant: a bad transform never fails the batch nor a sibling" do
    test "the failing subscription parks; the sibling delivers; the event is stamped", %{
      owner: owner
    } do
      # Two subscriptions on the same event, on independent connections so neither
      # lane blocks the other. s_bad's transform raises; s_ok is a no-op.
      conn_bad = create_connection!(owner)
      conn_ok = create_connection!(owner)
      s_bad = create_subscription!(conn_bad, "widget.updated", "error('boom')")
      s_ok = create_subscription!(conn_ok, "widget.updated")

      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      assert [bad] = events_for(s_bad)
      assert bad.state == :parked
      assert bad.last_error =~ "Transform error"

      assert [ok] = events_for(s_ok)
      assert ok.state == :pending

      # The batch committed; the event is dispatched despite the bad transform.
      assert [event] = Ash.read!(Event, authorize?: false)
      refute is_nil(event.dispatched_at)
    end
  end

  describe "atomicity: a failed materialize rolls the whole event back" do
    test "no dispatched_at, no duplicate delivery, error recorded", %{connection: conn} do
      s1 = create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})
      [event] = Ash.read!(Event, authorize?: false)

      # Pre-seed the exact delivery the fan-out will try to create, so the in-txn
      # insert hits the unique (event_id, subscription_id) identity and raises —
      # standing in for any infra failure mid-materialize.
      EventDelivery
      |> Ash.Changeset.for_create(
        :create,
        %{
          event_id: event.id,
          event_type: event.event_type,
          version: event.version,
          event_key: event.event_key,
          delivery: %{"pre" => "existing"},
          state: :pending,
          subscription_id: s1.id,
          connection_id: conn.id
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      drain_dispatch!()

      reloaded = reload(event)
      # Rolled back: not stamped, error recorded for re-emit, and the pre-existing
      # row is untouched (no duplicate inserted).
      assert is_nil(reloaded.dispatched_at)
      refute is_nil(reloaded.dispatch_error)
      assert Ash.count!(EventDelivery, authorize?: false) == 1
    end
  end

  describe "claim/1" do
    test "claims undispatched events, stamps the lease, and bumps attempts", %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})

      assert [claimed] = Dispatcher.claim(10)
      reloaded = reload(claimed)
      refute is_nil(reloaded.claimed_at)
      assert reloaded.dispatch_attempts == 1
    end

    test "does not re-claim an event still inside its lease window", %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})

      assert [_claimed] = Dispatcher.claim(10)
      assert [] = Dispatcher.claim(10)
    end

    test "skips events already dispatched", %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})

      drain_dispatch!()
      assert [] = Dispatcher.claim(10)
    end
  end

  describe "terminal (poison) events — never auto-resolved (#60)" do
    test "an event at the attempt ceiling is never re-claimed and stays stuck", %{
      connection: conn
    } do
      create_subscription!(conn, "widget.updated")
      poison = create_poison_event!()

      assert [] = Dispatcher.claim(10)
      drain_dispatch!()

      reloaded = reload(poison)
      assert is_nil(reloaded.dispatched_at)
      assert Ash.count!(EventDelivery, authorize?: false) == 0
    end

    test "recording a failure on a terminal event surfaces it but never stamps dispatched_at",
         %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      poison = create_poison_event!()

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:ash_integration, :dispatch, :poison]])

      Dispatcher.record_dispatch_errors([{poison.id, "connection refused"}])

      assert_received {[:ash_integration, :dispatch, :poison], ^ref, %{attempts: _}, %{}}
      reloaded = reload(poison)
      assert reloaded.dispatch_error =~ "poison"
      assert reloaded.dispatch_error =~ "connection refused"
      assert is_nil(reloaded.dispatched_at)
    end

    test "an undispatched event below the ceiling records the raw error", %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})
      [event] = Ash.read!(Event, authorize?: false)

      Dispatcher.record_dispatch_errors([{event.id, "transient blip"}])
      reloaded = reload(event)
      assert reloaded.dispatch_error == "transient blip"
      assert is_nil(reloaded.dispatched_at)
    end
  end

  describe "Broadway glue (prepare_messages → handle_message → handle_batch → ack)" do
    test "prepare_messages attaches per-event specs; handle_message routes to :default", %{
      connection: conn
    } do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})
      [event] = claimed_events()

      [prepared] = Relay.prepare_messages([message_for(event)], %{})
      assert %{event: ^event, subscriptions: [_], outcome: {:decision, _}} = prepared.data

      routed = Relay.handle_message(:default, prepared, %{})
      assert routed.batcher == :default
      assert %{specs: [_]} = routed.data
    end

    test "handle_batch materializes deliveries AND stamps dispatched_at in the transaction", %{
      connection: conn
    } do
      s1 = create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})
      [event] = claimed_events()

      messages =
        [message_for(event)]
        |> Relay.prepare_messages(%{})
        |> Enum.map(&Relay.handle_message(:default, &1, %{}))

      assert [%Broadway.Message{status: :ok}] = Relay.handle_batch(:default, messages, %{}, %{})

      assert [delivery] = events_for(s1)
      assert delivery.state == :pending
      # The stamp is the transaction's job now, not the ack's.
      refute is_nil(reload(event).dispatched_at)
    end

    test "Acknowledger records a dispatch_error for a failed message, leaves it undispatched", %{
      connection: conn
    } do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})
      [event] = Ash.read!(Event, authorize?: false)

      failed = Broadway.Message.failed(message_for(event), "boom")
      :ok = Acknowledger.ack(:ash_integration_dispatch, [], [failed])

      reloaded = reload(event)
      assert is_nil(reloaded.dispatched_at)
      assert reloaded.dispatch_error == "boom"
    end
  end

  describe "the real async pipeline" do
    test "an isolated start_supervised! relay claims and fans out an event end-to-end", %{
      connection: conn
    } do
      s1 = create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})
      [event] = Ash.read!(Event, authorize?: false)

      # An isolated, per-test pipeline (kept out of the app supervisor in :test). Its
      # producer claims the undispatched event from the (shared-sandbox) DB and runs
      # the real processor + batcher stages: project → transform → :dispatch txn.
      start_supervised!({Relay, name: :"relay_#{System.unique_integer([:positive])}"})

      assert eventually(fn -> match?([%{state: :pending}], events_for(s1)) end)
      refute is_nil(reload(event).dispatched_at)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp claimed_events, do: Dispatcher.claim(100)

  # Poll a condition for up to ~2s — for the one test that drives the real async
  # pipeline (everything else drains in-process and is deterministic).
  defp eventually(fun, retries \\ 40) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, retries - 1)
    end
  end

  defp message_for(event) do
    %Broadway.Message{data: event, acknowledger: Acknowledger.for_event(event.id)}
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

  defp create_subscription!(conn, event_type, transform_script \\ "-- noop") do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: conn.id,
        event_type: event_type,
        version: 1,
        transform_script: transform_script
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_widget!(attrs) do
    Widget
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # An Event past the attempt ceiling without dispatching — the terminal poison
  # case the relay must leave stuck. `dispatch_attempts` isn't in the create accept,
  # so force it.
  defp create_poison_event! do
    Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_type: "widget.updated",
        version: 1,
        event_key: "poison-key",
        source_resource: "widget",
        source_resource_id: "r1",
        source_action: "update",
        data: %{"id" => "r1"}
      },
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(
      :dispatch_attempts,
      AshIntegration.Outbound.Dispatch.Supervisor.max_attempts()
    )
    |> Ash.create!(authorize?: false)
  end

  defp events_for(subscription) do
    EventDelivery
    |> Ash.Query.filter(subscription_id == ^subscription.id)
    |> Ash.Query.load(:event)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)
end
