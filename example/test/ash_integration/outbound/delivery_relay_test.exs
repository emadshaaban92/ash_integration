defmodule Example.Outbound.DeliveryRelayTest do
  @moduledoc """
  Tests for the **delivery relay** (#81) — the Broadway pipeline that claims
  `:scheduled` `EventDelivery` rows and executes them, replacing the per-delivery
  Oban worker + the DeliveryGuardian.

  Covers the correctness contract the relay must hold:

    * claim semantics — lease, `attempts` bump on CLAIM, `next_attempt_at` backoff
      gate, the poison ceiling;
    * the in-process drain delivering a `:scheduled` row to `:delivered`;
    * a retryable failure → recorded + backoff + stays `:scheduled` (lane held);
    * lease re-claim re-delivers a row whose claimer "died" mid-flight (the deleted
      guardian's job);
    * terminal (poison) rows are never re-claimed and stay stuck (#60/#74);
    * the lease-token fence — a stale claimer cannot finalize a re-claimed row;
    * the real async pipeline over an isolated `start_supervised!` instance.
  """
  use Example.DataCase, async: false

  require Ash.Query
  import Ash.Expr
  import Example.IntegrationHelpers, only: [stub_webhook_success: 0, stub_webhook_failure: 1]

  alias AshIntegration.Outbound.Delivery.Dispatcher
  alias AshIntegration.Outbound.Delivery.Relay
  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

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

    test "does not claim a row whose next_attempt_at backoff has not elapsed", %{connection: conn} do
      d = scheduled_delivery!(create_subscription!(conn))

      # Simulate a recorded retryable failure: lease released, backoff in the future.
      set_fields!(d,
        claimed_at: nil,
        next_attempt_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

      assert [] = Dispatcher.claim(10)

      # Once the backoff is in the past, it becomes claimable again.
      set_fields!(d, next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
      assert [_claimed] = Dispatcher.claim(10)
    end

    test "never claims a terminal (poison) row at/over the attempt ceiling", %{connection: conn} do
      d = scheduled_delivery!(create_subscription!(conn))
      set_fields!(d, attempts: Stage.max_attempts())

      assert [] = Dispatcher.claim(10)
      assert reload(d).state == :scheduled
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

      drain_delivery!()

      assert reload(d).state == :delivered
    end

    test "a retryable failure records the error, stamps backoff, and stays :scheduled", %{
      connection: conn
    } do
      stub_webhook_failure(503)
      s = create_subscription!(conn)
      d = scheduled_delivery!(s)

      drain_delivery!()

      reloaded = reload(d)
      # Lane stays blocked (still scheduled) while it retries — in-order-per-key.
      assert reloaded.state == :scheduled
      assert reloaded.attempts == 1
      refute is_nil(reloaded.next_attempt_at)
      # Lease released so the backoff, not the lease, governs the retry.
      assert is_nil(reloaded.claimed_at)
      refute is_nil(reloaded.last_error)
      # A 5xx is a :response failure → the SUBSCRIPTION counter bumps.
      assert reload(s).consecutive_failures == 1
    end

    test "a suspended connection halts in-flight delivery back to :pending", %{connection: conn} do
      stub_webhook_success()
      d = scheduled_delivery!(create_subscription!(conn))
      suspend!(conn)

      drain_delivery!()

      assert reload(d).state == :pending
    end
  end

  describe "terminal (poison) — never auto-resolved (#60/#74)" do
    test "a row that crosses the ceiling is left :scheduled, surfaced once, never re-claimed", %{
      connection: conn
    } do
      stub_webhook_failure(503)
      d = scheduled_delivery!(create_subscription!(conn))
      # One claim away from the ceiling: the next (claim → fail) crosses it.
      set_fields!(d, attempts: Stage.max_attempts() - 1)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:ash_integration, :delivery, :poison]])

      drain_delivery!()

      assert_received {[:ash_integration, :delivery, :poison], ^ref, %{attempts: _}, %{}}
      reloaded = reload(d)
      assert reloaded.state == :scheduled
      assert reloaded.attempts == Stage.max_attempts()
      assert reloaded.last_error =~ "poison"
      # Terminal: never claimed again, stays stuck with its lane blocked.
      assert [] = Dispatcher.claim(10)
    end

    test "the terminal attempt does NOT bump the suspension counter (no double-penalty)", %{
      connection: conn
    } do
      stub_webhook_failure(503)
      s = create_subscription!(conn)
      d = scheduled_delivery!(s)
      # The next (claim → fail) crosses the ceiling, making this a poison attempt.
      set_fields!(d, attempts: Stage.max_attempts() - 1)

      drain_delivery!()

      assert reload(d).attempts == Stage.max_attempts()
      # A 5xx is normally a :response failure that bumps the SUBSCRIPTION counter —
      # but on the terminal/poison attempt it must NOT (the row already blocks its
      # lane forever; also suspending the subscription would be a double-penalty).
      assert reload(s).consecutive_failures == 0
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

  # ── Helpers ───────────────────────────────────────────────────────────────

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

  defp create_subscription!(conn) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: conn.id,
        event_type: "widget.updated",
        version: 1,
        transform_script: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # A `:scheduled` EventDelivery whose `delivery` descriptor is resolved through the
  # real Resolver (so the transport has a valid wire payload to replay).
  defp scheduled_delivery!(subscription, event_key \\ "p1") do
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

    {:ok, delivery} =
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
        state: :scheduled,
        subscription_id: subscription.id,
        connection_id: subscription.connection_id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)
end
