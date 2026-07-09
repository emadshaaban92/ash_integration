defmodule Example.Outbound.DeliveryRelayTest do
  @moduledoc """
  Tests for the **delivery relay** — the Broadway pipeline that claims
  `:scheduled` `EventDelivery` rows and executes them, replacing the per-delivery
  Oban worker + the DeliveryGuardian.

  Covers the correctness contract the relay must hold:

    * claim semantics — lease, `attempts` bump on CLAIM, `next_attempt_at` backoff
      gate, the poison ceiling;
    * the in-process drain delivering a `:scheduled` row to `:delivered`;
    * a retryable failure → recorded + backoff + stays `:scheduled` (lane held);
    * lease re-claim re-delivers a row whose claimer "died" mid-flight (the deleted
      guardian's job);
    * terminal (poison) rows are never re-claimed and stay stuck;
    * the lease-token fence — a stale claimer cannot finalize a re-claimed row;
    * the real async pipeline over an isolated `start_supervised!` instance.
  """
  use Example.DataCase, async: false

  require Ash.Query
  import Ash.Expr
  import Example.IntegrationHelpers, only: [stub_webhook_success: 0, stub_webhook_failure: 1]

  alias AshIntegration.Outbound.Delivery.Dispatcher
  alias AshIntegration.Outbound.Delivery.Health
  alias AshIntegration.Outbound.Delivery.Relay
  alias AshIntegration.Outbound.Delivery.Scheduler
  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage
  alias Example.Outbound.{Connection, Event, EventDelivery, Log, Subscription}

  setup do
    owner = create_user!()
    %{owner: owner, connection: create_connection!(owner)}
  end

  describe "claim/1" do
    test "claims due :scheduled rows, stamps the lease, and bumps attempts on claim", %{
      connection: conn
    } do
      s = create_subscription!(conn)
      d = scheduled_delivery!(s)

      assert [claimed] = Dispatcher.claim(10)
      assert claimed.id == d.id
      reloaded = reload(d)
      refute is_nil(reloaded.claimed_at)
      # The bump happens on the CLAIM, not on a graceful failure — so a crash
      # mid-send still increments and can't loop forever.
      assert reloaded.attempts == 1
    end

    test "does not re-claim a row still inside its lease window", %{connection: conn} do
      scheduled_delivery!(create_subscription!(conn))

      assert [_claimed] = Dispatcher.claim(10)
      assert [] = Dispatcher.claim(10)
    end

    test "claim ignores next_attempt_at — backoff is now a promotion-time gate", %{
      connection: conn
    } do
      # In this model the scheduler only promotes a row to `:scheduled` once it is due
      # (past its backoff), so a `:scheduled` row is by construction claimable. `claim/1`
      # therefore does NOT re-check `next_attempt_at` — a `:scheduled` row with a future
      # cursor (which shouldn't normally happen, but proves the gate moved) is still
      # leased. The backing-off gate is exercised in the scheduler describe below.
      d = scheduled_delivery!(create_subscription!(conn))

      set_fields!(d,
        claimed_at: nil,
        next_attempt_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

      assert [claimed] = Dispatcher.claim(10)
      assert claimed.id == d.id
    end

    test "never claims a non-:scheduled row (a :failed head is the scheduler's)", %{
      connection: conn
    } do
      # There is no attempt ceiling. A waiting/terminal row is `:failed`, not
      # `:scheduled`, so `claim/1` never leases it — re-promotion (`:failed → :scheduled`)
      # is the scheduler's job.
      d = scheduled_delivery!(create_subscription!(conn))
      set_fields!(d, state: :failed, attempts: 99)

      assert [] = Dispatcher.claim(10)
      assert reload(d).state == :failed
    end

    test "re-claims a row whose lease has expired (the deleted guardian's job)", %{
      connection: conn
    } do
      d = scheduled_delivery!(create_subscription!(conn))
      # A claimer that died mid-send: claimed_at stamped, but stale (older than the
      # lease window), attempts already bumped. The next pass must re-claim it.
      stale = DateTime.add(DateTime.utc_now(), -(Stage.lease_seconds() + 5), :second)
      set_fields!(d, claimed_at: stale, attempts: 1)

      assert [reclaimed] = Dispatcher.claim(10)
      assert reclaimed.id == d.id
      assert reload(d).attempts == 2
    end
  end

  describe "drain (real relay callbacks, in-process)" do
    test "delivers a :scheduled row and frees its slot", %{connection: conn} do
      stub_webhook_success()
      d = scheduled_delivery!(create_subscription!(conn))
      assert is_nil(d.delivered_at)

      drain_delivery!()

      delivered = reload(d)
      assert delivered.state == :delivered
      refute is_nil(delivered.delivered_at)
    end

    test "a retryable failure records the error, stamps backoff, and moves to :failed", %{
      connection: conn
    } do
      stub_webhook_failure(503)
      s = create_subscription!(conn)
      d = scheduled_delivery!(s)

      drain_delivery!()

      reloaded = reload(d)
      # Leaves the in-flight slot but keeps the lane as a `:failed` head (held via the
      # `{scheduled,failed}` index) while it waits out its backoff — in-order-per-key.
      assert reloaded.state == :failed
      assert is_nil(reloaded.terminal_reason)
      assert reloaded.attempts == 1
      refute is_nil(reloaded.next_attempt_at)
      # Lease released so the backoff, not the lease, governs the retry.
      assert is_nil(reloaded.claimed_at)
      refute is_nil(reloaded.last_error)
    end

    test "a suspended entity's :scheduled row is DELIVERED (recovery probe), not halted", %{
      connection: conn
    } do
      # Suspend first, THEN schedule — exactly what the recovery probe does (it
      # promotes one head for a suspended entity). `ParkOnSuspend` already ran on the
      # suspend transition, so this row stays `:scheduled` and is claimed with the
      # entity loaded as suspended. The relay no longer halts on suspension — it
      # delivers, so the probe actually reaches the transport.
      suspend!(conn)
      stub_webhook_success()
      d = scheduled_delivery!(create_subscription!(conn))

      drain_delivery!()

      # A probe success terminates the delivery (and a later recompute clears the
      # suspension off the logged success).
      assert reload(d).state == :delivered
    end

    test "a suspended entity's retryable failure is :failed with NO backoff (probe-paced)", %{
      connection: conn
    } do
      suspend!(conn)
      stub_webhook_failure(503)
      d = scheduled_delivery!(create_subscription!(conn))
      # It carries some prior attempts — `attempts` is monotonic and never reset now, so
      # the count keeps climbing honestly (there is no ceiling to protect against).
      set_fields!(d, attempts: 5)

      drain_delivery!()

      reloaded = reload(d)
      # Recorded `:failed` like any failure, but with NO backoff cursor: the recovery
      # probe (not the row's backoff) paces the next try, and on unsuspend the scheduler
      # promotes it immediately. `attempts` is untouched by the failure record.
      assert reloaded.state == :failed
      assert is_nil(reloaded.terminal_reason)
      assert is_nil(reloaded.next_attempt_at)
      assert is_nil(reloaded.claimed_at)
      assert reloaded.attempts == 6

      # The failure is still observable: a Log row classed `:probe` so it stays out of
      # the transport/response health windows.
      assert [log] = Ash.read!(Log, authorize?: false)
      assert log.status == :failed
      assert log.failure_class == :probe
      assert log.event_delivery_id == d.id
    end

    test "an unresolvable endpoint (base_url NXDOMAIN) is a :transport failure (connection scope)",
         %{owner: owner} do
      # An unresolvable base_url is a :transport failure at send, so a recompute
      # suspends the CONNECTION (not the subscription) — the dead endpoint surfaces.
      dead = create_connection!(owner, base_url: "https://wms.digitalhub.example.invalid/hook")
      s = create_subscription!(dead)
      d = scheduled_delivery!(s)

      with_window(1, fn ->
        with_egress_blocking(fn -> drain_delivery!() end)
        Health.recompute()
      end)

      assert reload(d).last_error =~ "egress blocked"
      assert reload(dead).suspended
      refute reload(s).suspended
    end

    test "an unresolvable endpoint drives the connection to suspension on recompute",
         %{owner: owner} do
      dead = create_connection!(owner, base_url: "https://wms.digitalhub.example.invalid/hook")
      s = create_subscription!(dead)
      d = scheduled_delivery!(s)

      # Window of 1: a single endpoint-transport failure trips on the next recompute.
      with_window(1, fn ->
        with_egress_blocking(fn -> drain_delivery!() end)
        Health.recompute()
      end)

      assert reload(dead).suspended
      refute is_nil(reload(d).last_error)
    end
  end

  describe "reflected-secret masking in delivery_metadata (the dashboard's full-detail view)" do
    test "stores the response body with a reflected outbound secret MASKED", %{connection: conn} do
      # A debug/echo target reflects our own live `Authorization`/`x-signature` back in
      # its body — that is OUR outbound credential and must never be persisted.
      echoed =
        "reflected request:\nauthorization: Bearer super-secret-token\n" <>
          "x-signature: t=1,v1=deadbeef\nstatus: ok"

      stub_webhook_body(200, echoed)
      d = scheduled_delivery!(create_subscription!(conn))

      drain_delivery!()

      delivered = reload(d)
      assert delivered.state == :delivered
      stored = delivered.delivery_metadata["response_body"]

      assert stored =~ "[REDACTED]"
      refute stored =~ "super-secret-token"
      refute stored =~ "deadbeef"
      # The OTHER system's actual content survives — this is the debugging view.
      assert stored =~ "status: ok"

      # The audit Log copy is likewise masked (re-masking is idempotent).
      assert [log] = Ash.read!(Log, authorize?: false)
      assert log.response_body =~ "[REDACTED]"
      refute log.response_body =~ "super-secret-token"
    end

    test "stores a normal (non-secret) response body VERBATIM — full length, unchanged", %{
      connection: conn
    } do
      body = ~s(warehouse=ACME-01; note=shipment received, 42 units; tracking=1Z999AA)
      stub_webhook_body(200, body)
      d = scheduled_delivery!(create_subscription!(conn))

      drain_delivery!()

      # The debugging use case: the dashboard shows exactly what the target sent.
      assert reload(d).delivery_metadata["response_body"] == body
    end
  end

  describe "terminal (:permanent) — non-retryable, terminal on the first attempt" do
    test "an HTTP 4xx is terminal at once (`:failed` + terminal_reason), surfaced, never re-claimed",
         %{connection: conn} do
      stub_webhook_failure(400)
      d = scheduled_delivery!(create_subscription!(conn))

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:ash_integration, :delivery, :terminal]])

      drain_delivery!()

      assert_received {[:ash_integration, :delivery, :terminal], ^ref, %{attempts: 1},
                       %{terminal_reason: :permanent}}

      reloaded = reload(d)
      # Terminal: `:failed` + an explicit verdict (NOT an inflated attempt count — the
      # count stays the truthful 1), holding its lane, no backoff cursor, never claimed.
      assert reloaded.state == :failed
      assert reloaded.terminal_reason == :permanent
      assert reloaded.attempts == 1
      assert is_nil(reloaded.next_attempt_at)
      assert is_nil(reloaded.claimed_at)
      assert [] = Dispatcher.claim(10)
    end

    test "a permanent failure is logged :permanent and never suspends the subscription", %{
      connection: conn
    } do
      stub_webhook_failure(400)
      s = create_subscription!(conn)
      d = scheduled_delivery!(s)

      # Window of 1: a single :response failure would trip the subscription next
      # recompute. A `:permanent` failure is excluded from the window, so it does not.
      with_window(1, fn ->
        drain_delivery!()
        Health.recompute()
      end)

      assert [log] = Ash.read!(Log, authorize?: false)
      assert log.status == :failed
      assert log.failure_class == :permanent
      assert log.event_delivery_id == d.id
      refute reload(s).suspended
    end

    test "a non-retryable failure while suspended is ALSO terminal, not probe-looped", %{
      connection: conn
    } do
      # A suspended entity's probe delivery that fails NON-retryably must not loop back
      # as a probe forever — a deterministic rejection can never recover, so it goes
      # terminal like any other permanent failure.
      suspend!(conn)
      stub_webhook_failure(400)
      d = scheduled_delivery!(create_subscription!(conn))

      drain_delivery!()

      reloaded = reload(d)
      assert reloaded.state == :failed
      assert reloaded.terminal_reason == :permanent
      assert [] = Dispatcher.claim(10)
    end
  end

  describe "lease-token fence (stale claimer can't finalize a re-claimed row)" do
    test ":deliver does not apply when the claimed_at token no longer matches", %{
      connection: conn
    } do
      d = scheduled_delivery!(create_subscription!(conn))
      token = DateTime.utc_now()
      set_fields!(d, claimed_at: token)

      # A stale claimer (it saw an OLDER token) tries to finalize: the fenced update
      # matches nothing, so the row is NOT resurrected to :delivered.
      stale_token = DateTime.add(token, -10, :second)

      reload(d)
      |> Ash.Changeset.for_update(:deliver, %{delivery_metadata: %{}}, authorize?: false)
      |> Ash.Changeset.filter(expr(claimed_at == ^stale_token))
      |> Ash.update(authorize?: false)

      assert reload(d).state == :scheduled

      # The legitimate claimer (matching token) finalizes it.
      reload(d)
      |> Ash.Changeset.for_update(:deliver, %{delivery_metadata: %{}}, authorize?: false)
      |> Ash.Changeset.filter(expr(claimed_at == ^token))
      |> Ash.update(authorize?: false)

      assert reload(d).state == :delivered
    end

    test ":deliver is guarded to :scheduled — a cancelled row can't be resurrected", %{
      connection: conn
    } do
      d = scheduled_delivery!(create_subscription!(conn))
      set_fields!(d, state: :cancelled)

      reload(d)
      |> Ash.Changeset.for_update(:deliver, %{delivery_metadata: %{}}, authorize?: false)
      |> Ash.update(authorize?: false)

      assert reload(d).state == :cancelled
    end
  end

  describe "transport raise (a bug) is recorded, not silently retried forever" do
    test "a raising transport records the row :failed with backoff instead of crashing the batch",
         %{connection: conn} do
      # A transport bug: instead of honoring the `{:ok, _}` / `{:error, _}` tuple
      # contract, `deliver_batch/2` raises. Unguarded this crashes the batcher —
      # Broadway fails the whole batch and the acknowledger records NOTHING, so the
      # row keeps its `:scheduled` state and silently retries at the lease cadence
      # forever (no `last_error`, no backoff). The relay must rescue it into a
      # per-row retryable failure that flows through the normal `record_failure` path.
      Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn _conn ->
        raise "boom: simulated transport bug"
      end)

      d = scheduled_delivery!(create_subscription!(conn))

      # The drain must complete — a rescued raise never propagates out of the batch.
      drain_delivery!()

      reloaded = reload(d)
      # Recorded like any healthy retryable failure: `:failed` head holding its lane,
      # a durable backoff cursor, the lease released, and a VISIBLE error — never a
      # terminal verdict (a transport bug is not the target's permanent rejection).
      assert reloaded.state == :failed
      assert is_nil(reloaded.terminal_reason)
      refute is_nil(reloaded.next_attempt_at)
      assert is_nil(reloaded.claimed_at)
      assert reloaded.last_error =~ "transport raised"
    end

    test "one connection's raise does not stop OTHER connections' rows from delivering", %{
      owner: owner
    } do
      # Each connection is its own batch (partitioned by `connection_id`), so a raise
      # confined to one batch must leave the others untouched — the healthy
      # connection's row still delivers.
      raising_conn = create_connection!(owner, base_url: "http://localhost:9999/raise")
      healthy_conn = create_connection!(owner, base_url: "http://localhost:9999/ok")
      raising = scheduled_delivery!(create_subscription!(raising_conn))
      healthy = scheduled_delivery!(create_subscription!(healthy_conn))

      # Both connections share the stubbed transport module, so key the behaviour off
      # the request path: raise for the raising connection, succeed for the healthy one.
      Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn conn ->
        if conn.request_path == "/raise" do
          raise "boom: simulated transport bug"
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ok"}))
        end
      end)

      drain_delivery!()

      assert reload(healthy).state == :delivered
      assert reload(raising).state == :failed
    end
  end

  describe "handle_batch/4 (Broadway contract)" do
    test "returns every received message, even on a mixed deliver + no-op batch", %{
      connection: conn
    } do
      # Broadway requires `handle_batch/4` to return ALL messages it was given. The
      # relay skips the `:noop` rows (state changed between claim and batch) and must
      # still pass them through — dropping any makes Broadway log an error per batch
      # and skips their normal ack.
      stub_webhook_success()
      s = create_subscription!(conn)
      scheduled_delivery!(s, "p-deliver")
      scheduled_delivery!(s, "p-noop")

      # Both rows share a connection, so they form one batch (batch_key). Flip one row
      # in-hand to a non-:scheduled state so the batch mixes a :deliver with a :noop
      # (the "cancelled/already-delivered between claim and execution" case).
      messages =
        Dispatcher.claim(10)
        |> Enum.sort_by(& &1.event_key)
        |> then(fn [deliver, noop] -> [deliver, %{noop | state: :cancelled}] end)
        |> Enum.map(&message/1)
        |> Enum.map(&Relay.handle_message(:default, &1, %{}))

      assert [:deliver, :noop] == Enum.map(messages, &Relay.decision(&1.data))

      returned = Relay.handle_batch(:default, messages, %{}, %{})

      # All received messages come back, with their status untouched (the relay never
      # uses Broadway status for retry — backoff/poison live in the DB).
      assert MapSet.new(returned, & &1.data.id) == MapSet.new(messages, & &1.data.id)
      assert Enum.all?(returned, &(&1.status == :ok))
    end
  end

  describe "the real async pipeline" do
    test "an isolated start_supervised! relay claims and delivers a row end-to-end", %{
      connection: conn
    } do
      stub_webhook_success()
      Req.Test.set_req_test_to_shared(self())
      d = scheduled_delivery!(create_subscription!(conn))

      start_supervised!({Relay, name: :"delivery_relay_#{System.unique_integer([:positive])}"})

      assert eventually(fn -> reload(d).state == :delivered end)
    end
  end

  # The crown-jewel invariant: for a lane `(connection_id, event_key)`, a later event is
  # never promoted ahead of an earlier one that is still an active head (`:scheduled`/
  # `:failed`). Enforced by the `{scheduled,failed}` unique index AND the scheduler's
  # lane-min selection. See design/delivery-retry-model.md §5, §17.
  describe "per-key ordering — the {scheduled,failed} lane invariant" do
    test "a backing-off :failed head holds its lane — a younger :pending row can't jump it",
         %{connection: conn} do
      s = create_subscription!(conn)
      e1 = scheduled_delivery!(s, "k")
      e2 = pending_delivery!(s, "k")
      # e1 failed and is waiting out a future backoff.
      set_fields!(e1,
        state: :failed,
        claimed_at: nil,
        next_attempt_at: DateTime.add(DateTime.utc_now(), 300, :second)
      )

      Scheduler.sweep()

      # The lane is held by e1 (backing off) — e2 stays put, e1 is not re-promoted yet.
      assert reload(e1).state == :failed
      assert reload(e2).state == :pending

      # Once e1's backoff elapses, e1 (the lane-min) — not e2 — is re-promoted.
      set_fields!(e1, next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
      Scheduler.sweep()

      assert reload(e1).state == :scheduled
      assert reload(e2).state == :pending
    end

    test "a terminal :failed head blocks its lane forever; skip (cancel) frees it", %{
      connection: conn
    } do
      s = create_subscription!(conn)
      e1 = scheduled_delivery!(s, "k")
      e2 = pending_delivery!(s, "k")
      set_fields!(e1, state: :failed, claimed_at: nil, terminal_reason: :permanent)

      Scheduler.sweep()
      # Blocked: the terminal head is never promoted and e2 never jumps it.
      assert reload(e1).state == :failed
      assert reload(e2).state == :pending

      # Operator skip: cancelling the terminal head frees the lane so e2 promotes.
      reload(e1)
      |> Ash.Changeset.for_update(:cancel, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      Scheduler.sweep()
      assert reload(e2).state == :scheduled
    end

    test "operator retry (:reprocess) clears the terminal verdict — a later retryable failure backs off instead of silently re-terminaling",
         %{connection: conn} do
      s = create_subscription!(conn)
      e1 = scheduled_delivery!(s, "k")
      set_fields!(e1, state: :failed, claimed_at: nil, terminal_reason: :permanent)

      # Operator "retry now": back to `:pending`, with the stale terminal verdict
      # cleared — otherwise the row's next retryable failure would land it back in
      # `:failed` still carrying `terminal_reason`, silently terminal again with no
      # `:terminal` telemetry.
      resurrected =
        reload(e1)
        |> Ash.Changeset.for_update(:reprocess, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      assert resurrected.state == :pending
      assert is_nil(resurrected.terminal_reason)

      # It re-promotes as its lane's head, fails retryably (503), and must be a
      # backing-off retry — NOT terminal.
      stub_webhook_failure(503)
      Scheduler.sweep()
      assert reload(e1).state == :scheduled

      drain_delivery!()

      failed = reload(e1)
      assert failed.state == :failed
      assert is_nil(failed.terminal_reason)
      refute is_nil(failed.next_attempt_at)
    end

    test "the unique index physically rejects a second active head on a lane", %{connection: conn} do
      s = create_subscription!(conn)
      _e1 = scheduled_delivery!(s, "k")
      e2 = pending_delivery!(s, "k")

      # Forcing e2 to a second active head (`:failed`) while e1 holds `:scheduled` must
      # be rejected by `idx_one_scheduled_per_connection_event_key` — ordering is a hard
      # DB guarantee, not merely query discipline.
      assert_raise Postgrex.Error, fn ->
        set_fields!(e2, state: :failed)
      end
    end

    test "delivering the head advances the lane to the next row", %{connection: conn} do
      stub_webhook_success()
      s = create_subscription!(conn)
      e1 = scheduled_delivery!(s, "k")
      e2 = pending_delivery!(s, "k")

      drain_delivery!()
      assert reload(e1).state == :delivered

      Scheduler.sweep()
      assert reload(e2).state == :scheduled
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Stub the webhook target to reply with an exact `body` (as `text/plain`, so Req
  # keeps it a raw binary — `body_to_string/1` then stores it byte-for-byte, letting
  # a test assert on the exact stored/masked response body).
  defp stub_webhook_body(status, body) do
    Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  # A Broadway message wrapping a claimed delivery, as the producer would emit it.
  defp message(delivery) do
    %Broadway.Message{data: delivery, acknowledger: Broadway.NoopAcknowledger.init()}
  end

  defp eventually(fun, retries \\ 40) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, retries - 1)
    end
  end

  # Direct attribute pokes (attempts / claimed_at / next_attempt_at / state) so a
  # test can construct an exact relay state no public action accepts — a raw Ecto
  # update on the backing table, the test analogue of a prior claim/failure.
  defp set_fields!(delivery, fields) do
    table = AshPostgres.DataLayer.Info.table(EventDelivery)

    from(r in {table, EventDelivery}, where: r.id == ^delivery.id)
    |> Example.Repo.update_all(set: fields)

    reload(delivery)
  end

  defp suspend!(connection) do
    connection
    |> Ash.Changeset.for_update(:suspend, %{reason: "test"}, authorize?: false)
    |> Ash.update!(authorize?: false)
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

  defp create_connection!(owner, opts \\ []) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: Keyword.get(opts, :base_url, "http://localhost:9999/webhook"),
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Run `fun` with the egress guard ON (the suite default is off), then restore it.
  defp with_egress_blocking(fun) do
    original = Application.get_env(:ash_integration, :egress)
    Application.put_env(:ash_integration, :egress, block_private?: true)

    try do
      fun.()
    after
      case original do
        nil -> Application.delete_env(:ash_integration, :egress)
        value -> Application.put_env(:ash_integration, :egress, value)
      end
    end
  end

  # Temporarily lower the auto-suspension threshold for a test, restoring it after.
  defp with_window(n, fun) do
    original = Application.get_env(:ash_integration, :health)
    Application.put_env(:ash_integration, :health, window_attempts: n)

    try do
      fun.()
    after
      case original do
        nil -> Application.delete_env(:ash_integration, :health)
        value -> Application.put_env(:ash_integration, :health, value)
      end
    end
  end

  defp create_subscription!(conn) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: conn.id,
        event_type: "widget.updated",
        version: 1,
        transform_source: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # A `:scheduled` EventDelivery whose `delivery` descriptor is resolved through the
  # real Resolver (so the transport has a valid wire payload to replay).
  defp scheduled_delivery!(subscription, event_key \\ "p1"),
    do: build_delivery!(subscription, event_key, :scheduled)

  # A `:pending` backlog row on a lane (a younger head can wait behind an active head).
  # Created directly `:pending` so it never occupies the `{scheduled,failed}` slot.
  defp pending_delivery!(subscription, event_key),
    do: build_delivery!(subscription, event_key, :pending)

  defp build_delivery!(subscription, event_key, state) do
    subscription = Ash.load!(subscription, [:connection], authorize?: false)
    data = %{"hello" => "world"}

    event =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          event_type: subscription.event_type,
          version: subscription.version,
          event_key: event_key,
          source_resource: "widget",
          source_resource_id: "r1",
          source_action: "update",
          data: data,
          dispatched_at: DateTime.utc_now()
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    envelope =
      AshIntegration.Outbound.Wire.Envelope.transform_input(%{
        id: event.id,
        type: subscription.event_type,
        version: subscription.version,
        event_key: event_key,
        created_at: event.created_at,
        subject: "r1",
        data: data
      })

    {:ok, delivery, _body_hash} =
      AshIntegration.Outbound.Delivery.Resolver.resolve(
        subscription.connection,
        subscription,
        envelope,
        event.created_at
      )

    EventDelivery
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_id: event.id,
        event_type: subscription.event_type,
        version: subscription.version,
        event_key: event_key,
        delivery: delivery,
        state: state,
        subscription_id: subscription.id,
        connection_id: subscription.connection_id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)
end
