defmodule Example.Outbound.TransportHttpOAuth2Test do
  @moduledoc """
  End-to-end coverage for the HTTP transport's OAuth2 client-credentials auth: the
  transport fetches an access token from the token endpoint (stubbed via
  `Req.Test`) and sends it as `Authorization: Bearer` on the webhook. The token is
  a live carve-out — fetched at delivery, cached across deliveries, never persisted
  in the stored descriptor.
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias AshIntegration.Transport.OAuth2.TokenCache
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  @token_stub AshIntegration.Transport.OAuth2

  setup do
    TokenCache.flush()
    on_exit(&TokenCache.flush/0)
    %{owner: create_user!()}
  end

  test "sends a Bearer token fetched from the token endpoint", %{owner: owner} do
    stub_token_endpoint()
    capture_webhook(self())

    dest = create_connection!(owner, auth: oauth2_auth())
    create_event!(create_subscription!(dest), data: %{"a" => 1})

    drain_delivery!()

    assert_received {:webhook_request, req}
    headers = Map.new(req.headers)
    assert headers["authorization"] == "Bearer tok-abc"
  end

  test "caches the token across deliveries (one token fetch for many sends)", %{owner: owner} do
    counter = :counters.new(1, [:atomics])

    Req.Test.stub(@token_stub, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.json(conn, %{"access_token" => "tok-abc", "expires_in" => 3600})
    end)

    capture_webhook(self())

    dest = create_connection!(owner, auth: oauth2_auth())
    sub = create_subscription!(dest)
    create_event!(sub, data: %{"a" => 1}, event_key: "k1")
    create_event!(sub, data: %{"b" => 2}, event_key: "k2")

    drain_delivery!()

    assert_received {:webhook_request, r1}
    assert_received {:webhook_request, r2}
    assert Map.new(r1.headers)["authorization"] == "Bearer tok-abc"
    assert Map.new(r2.headers)["authorization"] == "Bearer tok-abc"

    # Both deliveries shared one cached token.
    assert :counters.get(counter, 1) == 1
  end

  test "a bad-credentials token response fails the delivery non-retryably", %{owner: owner} do
    Req.Test.stub(@token_stub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_client"})
    end)

    dest = create_connection!(owner, auth: oauth2_auth())
    delivery = create_event!(create_subscription!(dest), data: %{"a" => 1})

    drain_delivery!()

    # The token fetch failed → the delivery recorded a classified :transport error
    # and never reached the webhook (which has no stub, so a send would have raised).
    assert failed_log_classes(:connection_id, dest.id) == [:transport]
    refute reload(delivery).state == :delivered
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp stub_token_endpoint do
    Req.Test.stub(@token_stub, fn conn ->
      Req.Test.json(conn, %{"access_token" => "tok-abc", "expires_in" => 3600})
    end)
  end

  defp capture_webhook(test_pid) do
    Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook_request, %{headers: conn.req_headers, body: body}})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ok"}))
    end)
  end

  defp oauth2_auth do
    %{
      type: "oauth2_client_credentials",
      token_url: "https://login.test/oauth2/token",
      client_id: "client-#{System.unique_integer([:positive])}",
      client_secret: "s3cr3t",
      scopes: "https://api.example.com/.default"
    }
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

  defp create_connection!(owner, opts) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "http://localhost:9999/webhook",
          auth: opts[:auth],
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_subscription!(dest, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          connection_id: dest.id,
          event_type: "widget.updated",
          version: 1,
          transform_source: "-- noop"
        },
        Map.new(overrides)
      )

    Subscription
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_event!(subscription, overrides) do
    overrides = Map.new(overrides)
    subscription = Ash.load!(subscription, [:connection], authorize?: false)
    data = Map.get(overrides, :data, %{"x" => 1})
    event_key = Map.get(overrides, :event_key, "p1")

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
    |> Ash.load!([:subscription, :connection], authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)

  defp failed_log_classes(:connection_id, id) do
    AshIntegration.delivery_log_resource()
    |> Ash.Query.filter(status == :failed and connection_id == ^id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.failure_class)
  end
end
