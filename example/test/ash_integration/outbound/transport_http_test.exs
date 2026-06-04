defmodule Example.Outbound.TransportHttpTest do
  @moduledoc """
  End-to-end tests for the event-first HTTP transport, driven through the **delivery
  relay** (claim → `Transport.deliver_batch` → `:deliver`/`:record_attempt_error`):
  the transport emits the §7 envelope and records success/failure, with failures
  classified as `:transport` (couldn't reach) vs `:response` (rejected) for
  two-level suspension. Delivery is driven in-process via the `drain_delivery!`
  DataCase helper.
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  import Example.IntegrationHelpers, only: [stub_webhook_capture: 1, stub_webhook_failure: 1]

  setup do
    %{connection: create_connection!(create_user!())}
  end

  test "delivers with the event-first envelope headers and the cached body", %{connection: dest} do
    stub_webhook_capture(self())

    s1 = create_subscription!(dest)
    event = create_event!(s1, data: %{"hello" => "world"})

    drain_delivery!()

    assert_received {:webhook_request, req}
    headers = Map.new(req.headers, fn {k, v} -> {k, v} end)

    assert headers["x-event-type"] == "widget.updated"
    assert headers["x-event-version"] == "1"
    # Wire event-id is the immutable Event id (shared across deliveries), not the
    # EventDelivery row id.
    assert headers["x-event-id"] == event.event_id
    # The default header set is intentionally minimal: id/type/version only.
    # created-at (informational), event-key (HTTP has no ordering; dedup uses
    # event-id) and connection-id (an internal UUID) are NOT sent by default —
    # a consumer that wants them adds them in the Lua transform.
    refute Map.has_key?(headers, "x-created-at")
    refute Map.has_key?(headers, "x-event-key")
    refute Map.has_key?(headers, "x-connection-id")
    # The body is the cached, post-transform payload — no CDC source leakage.
    assert Jason.decode!(req.body) == %{"hello" => "world"}
    refute Map.has_key?(headers, "x-resource")
    refute Map.has_key?(headers, "x-source-resource")

    assert reload(event).state == :delivered
  end

  test "delivers to the subscription's path + method joined onto the connection base_url", %{
    connection: dest
  } do
    stub_webhook_capture(self())

    sub =
      create_subscription!(dest, route_config: %{type: :http, path: "/widgets", method: :patch})

    event = create_event!(sub, data: %{"a" => 1})

    drain_delivery!()

    assert_received {:webhook_request, req}
    assert req.method == "PATCH"
    # base_url "http://localhost:9999/webhook" + path "/widgets"
    assert req.path == "/webhook/widgets"
  end

  test "defaults to POST at the base URL when the subscription sets no path/method", %{
    connection: dest
  } do
    stub_webhook_capture(self())

    event = create_event!(create_subscription!(dest), data: %{"a" => 1})

    drain_delivery!()

    assert_received {:webhook_request, req}
    assert req.method == "POST"
    assert req.path == "/webhook"
  end

  test "custom headers pass through but cannot shadow or duplicate wire headers" do
    stub_webhook_capture(self())

    dest =
      create_connection!(create_user!(),
        headers: %{"x-custom" => "keep-me", "X-Event-Type" => "spoofed"}
      )

    event = create_event!(create_subscription!(dest), data: %{"a" => 1})

    drain_delivery!()

    assert_received {:webhook_request, req}

    # A custom header with a non-reserved name passes through.
    assert {"x-custom", "keep-me"} in req.headers

    # The reserved wire header wins (case-insensitively) and is sent exactly once,
    # despite the destination trying to set "X-Event-Type".
    event_type_values =
      for {k, v} <- req.headers, String.downcase(k) == "x-event-type", do: v

    assert event_type_values == ["widget.updated"]
  end

  test "source/provenance is never emitted on the wire", %{connection: dest} do
    stub_webhook_capture(self())

    s1 = create_subscription!(dest)

    event =
      create_event!(s1,
        source_resource: "widget",
        source_resource_id: "r1",
        source_action: "update"
      )

    drain_delivery!()

    assert_received {:webhook_request, req}
    headers = Map.new(req.headers, fn {k, v} -> {k, v} end)

    refute Map.has_key?(headers, "x-source-resource")
    refute Map.has_key?(headers, "x-source-resource-id")
    refute Map.has_key?(headers, "x-source-action")
  end

  test "signs the post-transform body with HMAC under x-signature when a secret is set" do
    stub_webhook_capture(self())

    dest = create_connection!(create_user!(), signing_secret: "topsecret")
    s1 = create_subscription!(dest)
    event = create_event!(s1, data: %{"hello" => "world"})

    drain_delivery!()

    assert_received {:webhook_request, req}
    headers = Map.new(req.headers, fn {k, v} -> {k, v} end)

    assert sig = headers["x-signature"]
    # Format t=<ts>,v1=<hex>; recompute the HMAC over "<ts>.<body>" and match.
    assert %{"t" => ts, "v1" => v1} = parse_signature(sig)

    expected =
      :crypto.mac(:hmac, :sha256, "topsecret", "#{ts}.#{req.body}") |> Base.encode16(case: :lower)

    assert v1 == expected
  end

  test "auth is injected live at delivery from the encrypted connection (never in the descriptor)" do
    stub_webhook_capture(self())

    dest =
      create_connection!(create_user!(), auth: %{type: "bearer_token", token: "s3cret-token"})

    event = create_event!(create_subscription!(dest), data: %{"a" => 1})

    # The snapshotted descriptor must not carry the decrypted credential...
    refute Map.has_key?(event.delivery["headers"], "authorization")

    drain_delivery!()
    assert_received {:webhook_request, req}
    headers = Map.new(req.headers, fn {k, v} -> {k, v} end)

    # ...but the wire request does (resolved live from the encrypted connection).
    assert headers["authorization"] == "Bearer s3cret-token"
  end

  test "no signature header when no signing secret is configured", %{connection: dest} do
    stub_webhook_capture(self())
    event = create_event!(create_subscription!(dest), data: %{"a" => 1})

    drain_delivery!()

    assert_received {:webhook_request, req}
    headers = Map.new(req.headers, fn {k, v} -> {k, v} end)
    refute Map.has_key?(headers, "x-signature")
  end

  test "a 5xx response is a :response failure (subscription counter), retryable", %{
    connection: dest
  } do
    stub_webhook_failure(503)

    s1 = create_subscription!(dest)
    event = create_event!(s1)

    drain_delivery!()

    assert reload(s1).consecutive_failures == 1
    assert reload(dest).consecutive_failures == 0
  end

  test "a 4xx response is a :response failure, not retried", %{connection: dest} do
    stub_webhook_failure(422)

    s1 = create_subscription!(dest)
    event = create_event!(s1)

    # A 4xx is recorded as a `:response` failure (subscription counter); the row
    # stays `:scheduled` with a backoff. Two-level suspension is what halts a
    # persistently-rejecting subscription.
    drain_delivery!()
    assert reload(s1).consecutive_failures == 1
    assert reload(dest).consecutive_failures == 0
  end

  test "a connection error is a :transport failure (connection counter)", %{connection: dest} do
    Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn plug_conn ->
      Req.Test.transport_error(plug_conn, :econnrefused)
    end)

    s1 = create_subscription!(dest)
    event = create_event!(s1)

    drain_delivery!()

    assert reload(dest).consecutive_failures == 1
    assert reload(s1).consecutive_failures == 0
  end

  test "does not follow an HTTP redirect to an internal address (SSRF: redirect: false)", %{
    connection: dest
  } do
    test_pid = self()

    # The webhook answers every request with a 302 pointing at the cloud-metadata
    # endpoint. With `redirect: false` the transport must NOT chase it: the stub is
    # hit once (the original send to localhost) and never again for the internal
    # host — so a redirect can't be turned into an SSRF primitive. Egress is off in
    # the test config, so `redirect: false` is the *only* thing guarding this path
    # here, which is exactly what this test isolates.
    Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn plug_conn ->
      send(test_pid, {:redirect_target, plug_conn.host})

      plug_conn
      |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Plug.Conn.send_resp(302, "")
    end)

    s1 = create_subscription!(dest)
    event = create_event!(s1)

    drain_delivery!()

    # The original send happened…
    assert_received {:redirect_target, "localhost"}
    # …but the redirect to the metadata host was never chased.
    refute_received {:redirect_target, "169.254.169.254"}

    # A 302 is a non-2xx rejection: classified `:response` (subscription counter),
    # never delivered.
    refute reload(event).state == :delivered
    assert reload(s1).consecutive_failures == 1
    assert reload(dest).consecutive_failures == 0
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

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
    transport_config =
      %{
        type: :http,
        base_url: "http://localhost:9999/webhook",
        auth: opts[:auth] || %{type: "none"},
        timeout_ms: 5000
      }
      |> then(fn tc ->
        case opts[:signing_secret] do
          nil -> tc
          secret -> Map.put(tc, :signing_secret, secret)
        end
      end)
      |> then(fn tc ->
        case opts[:headers] do
          nil -> tc
          headers -> Map.put(tc, :headers, headers)
        end
      end)

    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: transport_config
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp parse_signature(sig) do
    sig
    |> String.split(",")
    |> Map.new(fn part ->
      [k, v] = String.split(part, "=", parts: 2)
      {k, v}
    end)
  end

  defp create_subscription!(dest, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          connection_id: dest.id,
          event_type: "widget.updated",
          version: 1,
          transform_script: "-- noop"
        },
        Map.new(overrides)
      )

    Subscription
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # Builds a `:scheduled` event whose `delivery` descriptor is RESOLVED through the
  # real `Resolver` (so these stay end-to-end: resolve → snapshot → replay).
  # `data:` is the event data (the body before encoding). Other keys override the
  # event row directly. The Event id is DB-generated (wire event-id = that id).
  defp create_event!(subscription, overrides \\ []) do
    overrides = Map.new(overrides)
    subscription = Ash.load!(subscription, [:connection], authorize?: false)
    data = Map.get(overrides, :data, %{"x" => 1})
    event_key = Map.get(overrides, :event_key, "p1")

    # The immutable fact first (its DB-generated id is the wire event-id) …
    event =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          event_type: subscription.event_type,
          version: subscription.version,
          event_key: event_key,
          source_resource: Map.get(overrides, :source_resource, "widget"),
          source_resource_id: Map.get(overrides, :source_resource_id, "r1"),
          source_action: Map.get(overrides, :source_action, "update"),
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

    # … and the delivery carrying the resolved descriptor the transport replays.
    delivery_attrs =
      Map.merge(
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
        Map.drop(overrides, [
          :data,
          :id,
          :snapshot,
          :source_resource,
          :source_resource_id,
          :source_action
        ])
      )

    EventDelivery
    |> Ash.Changeset.for_create(:create, delivery_attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
    |> Ash.load!([:subscription, :connection], authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)
end
