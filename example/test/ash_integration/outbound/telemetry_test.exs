defmodule Example.Outbound.TelemetryTest do
  @moduledoc """
  Coverage for the outbound pipeline's `:telemetry` events: `:parked` (at dispatch
  and on a reprocess re-park), `:suspended`/`:unsuspended`/`:resumed`, and
  `:delivered`. See `AshIntegration.Telemetry` for the full reference.
  """
  use Example.DataCase, async: false

  import Example.IntegrationHelpers,
    only: [create_user!: 0, stub_webhook_success: 0, stub_webhook_failure: 1]

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Health
  alias AshIntegration.Outbound.Delivery.Reprocessor
  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  setup do
    owner = create_user!()
    %{owner: owner, connection: create_connection!(owner)}
  end

  describe "[:ash_integration, :delivery, :parked]" do
    test "a broken transform parks at dispatch and emits :parked (failure_kind :transform)", %{
      connection: dest
    } do
      seed_subscription!(dest, ~s|error("boom")|)

      ref = attach([[:ash_integration, :delivery, :parked]])

      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      assert_received {[:ash_integration, :delivery, :parked], ^ref, %{count: 1}, meta}
      assert meta.failure_kind == :transform
      assert meta.reason =~ "Transform error"
      assert meta.event_type == "widget.updated"
      assert meta.connection_id == dest.id
      refute is_nil(meta.event_id)
      refute is_nil(meta.subscription_id)

      assert single_delivery().state == :parked
    end

    test "a reprocess that re-parks re-emits :parked", %{connection: dest} do
      sub = seed_subscription!(dest, ~s|error("boom")|)

      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()
      parked = single_delivery()
      assert parked.state == :parked

      # Transform still broken, so reprocessing re-parks — which re-emits.
      ref = attach([[:ash_integration, :delivery, :parked]])
      assert {:error, _} = Reprocessor.reprocess_event(parked)

      assert_received {[:ash_integration, :delivery, :parked], ^ref, %{count: 1}, meta}
      assert meta.failure_kind == :transform
      assert meta.subscription_id == sub.id
    end
  end

  describe "derived suspension" do
    test "a recompute over N transport failures emits [:ash_integration, :connection, :suspended]",
         %{owner: owner} do
      dead = create_connection!(owner, base_url: "https://wms.unreachable.example.invalid/hook")
      s = create_subscription!(dead)
      d = scheduled_delivery!(s)

      ref = attach([[:ash_integration, :connection, :suspended]])

      with_window(1, fn ->
        with_egress_blocking(fn -> drain_delivery!() end)
        Health.recompute()
      end)

      assert_received {[:ash_integration, :connection, :suspended], ^ref, %{count: 1}, meta}

      assert meta.id == dead.id
      assert meta.window_attempts == 1
      assert meta.failure_class == "transport"

      assert reload(dead).suspended
      assert reload(d).last_error
    end

    test "a recompute over N response failures emits [:ash_integration, :subscription, :suspended]",
         %{connection: conn} do
      stub_webhook_failure(503)
      s = create_subscription!(conn)
      scheduled_delivery!(s)

      ref = attach([[:ash_integration, :subscription, :suspended]])

      with_window(1, fn ->
        drain_delivery!()
        Health.recompute()
      end)

      assert_received {[:ash_integration, :subscription, :suspended], ^ref, %{count: 1}, meta}

      assert meta.id == s.id
      assert meta.window_attempts == 1
      assert meta.failure_class == "response"

      assert reload(s).suspended
    end

    test "unsuspending a connection emits :unsuspended; resuming a subscription emits :resumed",
         %{
           connection: conn
         } do
      conn = suspend!(conn)
      s = suspend!(create_subscription!(conn))

      ref =
        attach([
          [:ash_integration, :connection, :unsuspended],
          [:ash_integration, :subscription, :resumed]
        ])

      unsuspend!(conn)
      unsuspend!(s)

      assert_received {[:ash_integration, :connection, :unsuspended], ^ref, %{count: 1},
                       %{id: conn_id}}

      assert conn_id == conn.id

      assert_received {[:ash_integration, :subscription, :resumed], ^ref, %{count: 1},
                       %{id: sub_id}}

      assert sub_id == s.id

      refute reload(conn).suspended
      refute reload(s).suspended
    end
  end

  describe "[:ash_integration, :delivery, :delivered]" do
    test "a successful send emits :delivered with attempts + duration_ms and metadata", %{
      connection: conn
    } do
      stub_webhook_success()
      s = create_subscription!(conn)
      d = scheduled_delivery!(s)

      # Backdate the source Event so duration_ms reflects source-change → ack
      # (Event.created_at), not dispatch → ack (EventDelivery.created_at).
      backdate_event!(d.event_id, 5_000)

      ref = attach([[:ash_integration, :delivery, :delivered]])

      drain_delivery!()

      assert_received {[:ash_integration, :delivery, :delivered], ^ref, measurements, meta}
      assert measurements.count == 1
      # `attempts` is the post-claim value (bumped on claim) — at least one.
      assert measurements.attempts >= 1
      # Measured from the (backdated) Event, so at least the backdate.
      assert measurements.duration_ms >= 5_000

      assert meta.event_delivery_id == d.id
      assert meta.event_type == "widget.updated"
      assert meta.subscription_id == s.id
      assert meta.connection_id == conn.id
      assert meta.transport == :http

      assert reload(d).state == :delivered
    end

    test "a stale claimer that loses the lease race does NOT emit :delivered", %{connection: conn} do
      stub_webhook_success()
      d = scheduled_delivery!(create_subscription!(conn))
      token = DateTime.utc_now()
      set_fields!(d, claimed_at: token)

      # Simulate the relay finalizing with a STALE token (another pass re-claimed
      # the row): the fenced `:deliver` matches nothing, so no delivery happened.
      ref = attach([[:ash_integration, :delivery, :delivered]])

      stale =
        EventDelivery
        |> Ash.get!(d.id, load: [:connection, :subscription], authorize?: false)
        |> Map.put(:claimed_at, DateTime.add(token, -10, :second))

      drain_with_message(stale)

      refute_received {[:ash_integration, :delivery, :delivered], ^ref, _, _}
    end
  end

  # ── Helpers (modeled on delivery_relay_test / reprocessor_test) ─────────────

  defp attach(events), do: :telemetry_test.attach_event_handlers(self(), events)

  defp single_delivery do
    [d] = EventDelivery |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)
    d
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

  # A subscription whose transform raises at dispatch, seeded PAST the save-time
  # smoke gate so the dispatch-time park path is reached.
  defp seed_subscription!(conn, transform_source) do
    Ash.Seed.seed!(Subscription, %{
      connection_id: conn.id,
      event_type: "widget.updated",
      version: 1,
      transform_source: transform_source,
      active: true,
      suspended: false
    })
  end

  defp create_widget!(attrs) do
    Widget
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # A `:scheduled` EventDelivery whose descriptor is resolved through the real
  # Resolver, so the transport has a valid wire payload to replay.
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
        state: :scheduled,
        subscription_id: subscription.id,
        connection_id: subscription.connection_id
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp suspend!(record) do
    record
    |> Ash.Changeset.for_update(:suspend, %{reason: "test"}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp unsuspend!(record) do
    record
    |> Ash.Changeset.for_update(:unsuspend, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp set_fields!(delivery, fields) do
    table = AshPostgres.DataLayer.Info.table(EventDelivery)

    from(r in {table, EventDelivery}, where: r.id == ^delivery.id)
    |> Example.Repo.update_all(set: fields)

    reload(delivery)
  end

  defp backdate_event!(event_id, ms_ago) do
    table = AshPostgres.DataLayer.Info.table(Event)
    at = DateTime.add(DateTime.utc_now(), -ms_ago, :millisecond)

    from(e in {table, Event}, where: e.id == ^event_id)
    |> Example.Repo.update_all(set: [created_at: at])
  end

  # Drive the relay's deliver path for a single in-hand message (used to exercise
  # the stale-claimer fence without a real claim).
  defp drain_with_message(delivery) do
    alias AshIntegration.Outbound.Delivery.Acknowledger
    alias AshIntegration.Outbound.Delivery.Relay

    message = %Broadway.Message{
      data: delivery,
      acknowledger: Acknowledger.for_delivery(delivery.id)
    }

    msg = Relay.handle_message(:default, message, %{})
    Relay.handle_batch(:default, [msg], %{}, %{})
  end

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

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)
end
