defmodule Example.Outbound.DispatchRelayTest do
  @moduledoc """
  Tests for the outbox **dispatch relay** (outbound-architecture.md §6).

  Capture writes only undispatched `Event` rows; the relay claims them and fans
  them out. Prep (`project` + transform) runs in the Broadway processor stage
  (`prepare_messages`/`handle_message`); the `:dispatch` action then stamps
  `dispatched_at` AND materializes deliveries + coalesces in ONE transaction
  (`handle_batch`). We cover:

    * the outbox contract (capture enqueues no job; Events start undispatched);
    * the in-process drain (real relay callbacks) materializing + stamping;
    * **batched `project`** — one call per (type, version);
    * the isolation invariant — a bad transform parks only its own delivery, never the
      batch, and never a sibling subscription;
    * atomicity — a failed materialize rolls the whole event back (nothing stamped);
    * claim semantics, terminal (poison) events;
    * the Broadway glue (`prepare_messages`/`handle_message`/`handle_batch`/ack);
    * the real async pipeline over an isolated `start_supervised!` instance.
  """
  use Example.DataCase, async: false
  use Mimic

  require Ash.Query

  alias AshIntegration.Outbound.Dispatch.Acknowledger
  alias AshIntegration.Outbound.Dispatch.Relay
  alias AshIntegration.Outbound.Dispatch.Dispatcher
  alias AshIntegration.Outbound.Dispatch.RelayProducer
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

  describe "batched project (open question)" do
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

  describe "isolation invariant: a bad transform never fails the batch nor a sibling" do
    test "the failing subscription parks; the sibling delivers; the event is stamped", %{
      owner: owner
    } do
      # Two subscriptions on the same event, on independent connections so neither
      # lane blocks the other. s_bad's transform raises; s_ok is a no-op.
      conn_bad = create_connection!(owner)
      conn_ok = create_connection!(owner)
      # Seed s_bad past the save-time smoke gate (which now rejects a script that
      # raises on the producer's example/1) to reach the dispatch-time park path.
      s_bad =
        Ash.Seed.seed!(Subscription, %{
          connection_id: conn_bad.id,
          event_type: "widget.updated",
          version: 1,
          transform_source: "error('boom')",
          active: true,
          suspended: false
        })

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

    test "a reload failure rolls the lease + attempt bump back (no orphaned claim)", %{
      connection: conn
    } do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})

      # The lease UPDATE commits inside the claim transaction, then the reload blips. The
      # reload shares that transaction, so its failure rolls the UPDATE back with it — the
      # row must be left exactly as it was (claimable, attempts still 0), not leased-but-
      # unemitted for a full lease window with `dispatch_attempts` silently burned.
      stub(Ash, :read, fn _query, _opts ->
        {:error, Ash.Error.Unknown.exception(errors: [%RuntimeError{message: "db blip"}])}
      end)

      assert [] = Dispatcher.claim(10)

      # Assert via raw SQL — `Ash.read` is stubbed to fail for this process.
      assert %{rows: [[nil, 0]]} =
               Repo.query!("SELECT claimed_at, dispatch_attempts FROM outbound_events LIMIT 1")
    end
  end

  # The claim opens its transaction directly on the repo with `log: query_log_level()`,
  # so `false` silences not just the claim UPDATE but the `begin`/`commit` envelope too —
  # the whole point: an idle poll (0 rows) leaves no trace in the host log. We drop the
  # *primary* level to `:debug` to observe it (test env pins `:warning`, which would filter
  # the `:debug` transaction log before any handler sees it). Safe only because this module
  # is `async: false`.
  describe "query_log_level (claim transaction envelope)" do
    setup do
      original = Application.fetch_env(:ash_integration, :query_log_level)
      primary_level = Logger.level()

      on_exit(fn ->
        Logger.configure(level: primary_level)

        case original do
          {:ok, value} -> Application.put_env(:ash_integration, :query_log_level, value)
          :error -> Application.delete_env(:ash_integration, :query_log_level)
        end
      end)

      :ok
    end

    test "false silences the whole claim transaction, envelope included (idle poll)" do
      Application.put_env(:ash_integration, :query_log_level, false)

      {claimed, log} = claim_with_log()

      assert claimed == [], "no undispatched events — the claim matches 0 rows"
      refute log =~ "begin", "the transaction begin must be silenced, not just the UPDATE"
      refute log =~ "commit", "the transaction commit must be silenced too"
      refute log =~ "outbound_events", "the claim UPDATE must be silenced"
    end

    test ":debug still logs the begin/commit envelope" do
      Application.put_env(:ash_integration, :query_log_level, :debug)

      {claimed, log} = claim_with_log()

      assert claimed == []
      assert log =~ "begin", "at :debug the transaction begin must still appear"
      assert log =~ "commit", "at :debug the transaction commit must still appear"
    end
  end

  describe "producer: a mid-drain claim failure never drops already-built messages" do
    test "emits the messages from earlier chunks when a later chunk's claim raises" do
      # Two undispatched events the mocked claim hands back one chunk at a time.
      [e1, e2] = [%Event{id: Ash.UUIDv7.generate()}, %Event{id: Ash.UUIDv7.generate()}]

      # Chunk 1 claims + builds e1; chunk 2 raises (a reload blip that somehow escaped
      # Dispatcher.claim). The producer must still emit e1: its row is already leased, so
      # dropping the message would strand it invisible for a full lease window.
      Dispatcher
      |> expect(:claim, fn _ -> [e1] end)
      |> expect(:claim, fn _ -> raise "reload blip" end)

      {:noreply, messages, new_state} =
        RelayProducer.handle_demand(2, producer_state(claim_limit: 1))

      assert [%Broadway.Message{data: ^e1}] = messages
      # The unclaimed demand is held for the next poll, not lost.
      assert new_state.demand == 1
      refute e2.id == e1.id
    end

    test "a claim failure on the very first chunk emits nothing and holds all demand" do
      expect(Dispatcher, :claim, fn _ -> raise "reload blip" end)

      {:noreply, messages, new_state} =
        RelayProducer.handle_demand(3, producer_state(claim_limit: 2))

      assert messages == []
      assert new_state.demand == 3
    end
  end

  describe "terminal (poison) events — never auto-resolved" do
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

    test "records the error for a whole failed batch without stamping dispatched_at", %{
      connection: conn
    } do
      create_subscription!(conn, "widget.updated")
      for i <- 1..5, do: create_widget!(%{name: "w#{i}", stock: 1})
      events = Ash.read!(Event, authorize?: false)
      assert length(events) == 5

      # A whole-batch infra failure: every event fails with the same reason. This
      # is the path the bulk update targets — one query for the shared reason.
      Dispatcher.record_dispatch_errors(Enum.map(events, &{&1.id, "connection refused"}))

      for event <- events do
        reloaded = reload(event)
        assert reloaded.dispatch_error == "connection refused"
        assert is_nil(reloaded.dispatched_at)
      end
    end

    test "ignores ids that are not in the outbox", %{connection: conn} do
      create_subscription!(conn, "widget.updated")
      create_widget!(%{name: "w", stock: 1})
      [event] = Ash.read!(Event, authorize?: false)

      # A mix of a real event and a stale/unknown id — the unknown one is simply
      # absent from the bulk read and recorded for no one.
      assert :ok =
               Dispatcher.record_dispatch_errors([
                 {event.id, "real"},
                 {Ash.UUIDv7.generate(), "ghost"}
               ])

      assert reload(event).dispatch_error == "real"
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

  describe "batch atomicity above Ash's default 100-row chunk (item 1)" do
    test "a >100-event batch commits as one transaction; a poison row never strands committed batchmates",
         %{connection: conn} do
      s1 = create_subscription!(conn, "widget.updated")
      for _ <- 1..101, do: create_widget!(%{name: "w", stock: 1})

      events = Event |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)
      assert length(events) == 101

      # Pre-seed the NEWEST event's delivery so its in-txn materialize hits the
      # unique (event_id, subscription_id) identity and raises — a stand-in for any
      # mid-batch infra failure, placed so it lands in the SECOND default 100-chunk.
      poison = List.last(events)
      seed_conflicting_delivery!(poison, s1, conn)

      claimed = Dispatcher.claim(200)
      assert length(claimed) == 101, "the whole >100 batch must be claimed at once"

      results = run_batch(claimed)

      # Pinning bulk_update's `batch_size` to the batch length makes the whole fan-out
      # ONE transaction: the poison rolls it all back → `retry_one` re-dispatches each
      # event in its own txn → the 100 healthy events commit, only the poison fails.
      # Under Ash's default `batch_size: 100` the first chunk would have committed and
      # `retry_one` would then re-dispatch those already-committed events (failing).
      assert Enum.count(results, &(&1.status == :ok)) == 100
      assert Enum.count(results, &match?({:failed, _}, &1.status)) == 1

      failed = Enum.find(results, &match?({:failed, _}, &1.status))
      assert failed.data.event.id == poison.id

      healthy = Enum.reject(events, &(&1.id == poison.id))
      assert Enum.all?(healthy, &(not is_nil(reload(&1).dispatched_at)))
      # No duplicate deliveries: 100 healthy + the 1 pre-seeded poison row.
      assert Ash.count!(EventDelivery, authorize?: false) == 101
    end
  end

  describe "the dispatched_at IS NULL idempotency guard (lease-expiry re-claim, item 2)" do
    test "a re-claimed already-dispatched skip-plan event is not re-stamped", %{connection: _conn} do
      # A skip-plan event (no subscribers) stamps `dispatched_at` but writes no
      # deliveries and has no unique identity guarding it. Simulate the fixed 60s
      # lease expiring mid-fan-out: pass A dispatches + stamps, then pass B — still
      # holding the pre-stamp claim — must be a NO-OP, not a silent re-stamp.
      event = seed_bare_event!()
      [claimed] = Dispatcher.claim(10)
      assert claimed.id == event.id

      run_batch([claimed])
      t1 = reload(event).dispatched_at
      refute is_nil(t1)

      # Pass B reuses the SAME pre-stamp struct (dispatched_at still nil in memory);
      # the guard pushes `AND dispatched_at IS NULL` onto the UPDATE, so it matches
      # zero rows and the write is a dropped StaleRecord — no re-stamp.
      run_batch([claimed])

      assert reload(event).dispatched_at == t1,
             "a re-claimed already-dispatched event must not have dispatched_at re-stamped"

      assert Ash.count!(EventDelivery, authorize?: false) == 0
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

  # Run a claim with the primary Logger level temporarily at :debug so the claim's
  # transaction log is observable, returning `{claimed, captured_log}`. The primary
  # level is restored by the "query_log_level" describe's `on_exit`.
  defp claim_with_log do
    Logger.configure(level: :debug)
    ExUnit.CaptureLog.with_log(fn -> Dispatcher.claim(10) end)
  end

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

  # Drive the real batcher stage for a claimed set in one shot (prepare → handle →
  # handle_batch), returning the resulting messages, WITHOUT the per-100 chunking of
  # `drain_dispatch!` (which claims 100 at a time). Lets a test hand `handle_batch` a
  # >100-message batch directly.
  defp run_batch(events) do
    events
    |> Enum.map(&message_for/1)
    |> Relay.prepare_messages(%{})
    |> Enum.map(&Relay.handle_message(:default, &1, %{}))
    |> then(&Relay.handle_batch(:default, &1, %{}, %{}))
  end

  # Pre-seed the exact delivery the fan-out will try to create, so its in-txn insert
  # hits the unique (event_id, subscription_id) identity and raises.
  defp seed_conflicting_delivery!(event, subscription, connection) do
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
        subscription_id: subscription.id,
        connection_id: connection.id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # A directly-seeded, undispatched Event with no subscribers — a "skip-plan" event
  # (dispatch stamps it but writes no deliveries).
  defp seed_bare_event! do
    Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_type: "widget.updated",
        version: 1,
        event_key: "k-#{System.unique_integer([:positive])}",
        source_resource: "widget",
        source_resource_id: "r1",
        source_action: "update",
        data: %{"id" => "r1"}
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
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

  defp create_subscription!(conn, event_type, transform_source \\ "-- noop") do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: conn.id,
        event_type: event_type,
        version: 1,
        transform_source: transform_source
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

  # A minimal producer state for driving `handle_demand/2` directly (in-process, so the
  # Mimic `Dispatcher.claim` stub applies). The poll timer is irrelevant here.
  defp producer_state(opts) do
    %{
      demand: 0,
      poll_interval: 60_000,
      claim_limit: Keyword.fetch!(opts, :claim_limit),
      poll_timer: nil,
      draining: false
    }
  end
end
