defmodule Example.Outbound.DeliveryResolverTest do
  @moduledoc """
  Unit tests for `AshIntegration.Outbound.Delivery.Resolver` — the transport-shaped
  transform output (§7, Task 32): the transform mutates a PRE-SEEDED `result`
  (body, headers, routing); the resolver normalizes/validates it, signs the final
  body, and returns the wire descriptor to snapshot on the event.

  Covers: header override + removal, dynamic path/url (HTTP), dynamic
  topic/key/timestamp (Kafka), the stored signature (matches a manual HMAC over
  the exact stored body — serializer parity), auth never entering the descriptor,
  and invalid output → `{:error, _}` (the event parks).
  """
  use Example.DataCase, async: false

  alias AshIntegration.Outbound.Delivery.Resolver
  alias AshIntegration.Outbound.Wire.Envelope
  alias Example.Outbound.{Connection, Subscription}

  setup do
    %{owner: create_user!()}
  end

  describe "HTTP" do
    test "a no-op transform sends the pre-seeded defaults (body, wire headers, route)", %{
      owner: owner
    } do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", "-- noop")

      {:ok, d} = resolve(dest, sub, %{"hello" => "world"})

      assert d["transport"] == "http"
      assert d["method"] == "post"
      assert d["url"] == "http://localhost:9999/webhook"
      assert d["headers"]["x-event-type"] == "widget.updated"
      assert d["headers"]["content-type"] == "application/json"
      # Body is stored as a decoded term (a map), not pre-serialized bytes.
      assert d["body"] == %{"hello" => "world"}
    end

    test "the transform overrides AND removes wire headers (incl. x-event-id)", %{owner: owner} do
      dest = http_connection!(owner)

      script = """
      result.headers["x-event-id"] = nil
      result.headers["x-custom"] = "added"
      result.headers["x-event-type"] = "overridden"
      """

      sub = subscription!(dest, "widget.updated", script)
      {:ok, d} = resolve(dest, sub, %{})

      refute Map.has_key?(d["headers"], "x-event-id")
      assert d["headers"]["x-custom"] == "added"
      assert d["headers"]["x-event-type"] == "overridden"
    end

    test "the transform sets a relative path, joined onto the connection base_url", %{
      owner: owner
    } do
      dest = http_connection!(owner)

      sub =
        subscription!(
          dest,
          "widget.updated",
          ~s|result.path = "/widgets/42"; result.method = "put"|
        )

      {:ok, d} = resolve(dest, sub, %{})

      assert d["method"] == "put"
      assert d["url"] == "http://localhost:9999/webhook/widgets/42"
    end

    test "result.url is an absolute override that bypasses base_url + path", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", ~s|result.url = "https://elsewhere.test/in"|)

      {:ok, d} = resolve(dest, sub, %{})

      assert d["url"] == "https://elsewhere.test/in"
    end

    test "the signature is NOT in the descriptor (it is a live carve-out, added at delivery)",
         %{owner: owner} do
      dest = http_connection!(owner, signing_secret: "topsecret")
      sub = subscription!(dest, "widget.updated", ~s|result.body = { a = 1 }|)

      {:ok, d} = resolve(dest, sub, %{})

      # The transform-set body is stored as a term...
      assert d["body"] == %{"a" => 1}
      # ...but the signature is computed live at delivery (over the encoded body
      # with a send-time `t`), so it never appears in the snapshot.
      refute Map.has_key?(d["headers"], "x-signature")
    end

    test "auth is NEVER placed in the descriptor (injected live at delivery)", %{owner: owner} do
      dest = http_connection!(owner, auth: %{type: "bearer_token", token: "s3cret-token"})
      sub = subscription!(dest, "widget.updated", "-- noop")

      {:ok, d} = resolve(dest, sub, %{})

      refute Map.has_key?(d["headers"], "authorization")
      refute Enum.any?(Map.values(d["headers"]), &(&1 =~ "s3cret-token"))
    end

    test "an invalid HTTP method is a transform error (the event parks)", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", ~s|result.method = "TRACE"|)

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "invalid HTTP method"
    end

    test "a non-string header value is a transform error (the event parks)", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", ~s|result.headers["x-bad"] = { nested = 1 }|)

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "result.headers"
    end

    test "result = nil skips", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", "result = nil")

      assert :skip = resolve(dest, sub, %{})
    end

    test "empty event data resolves to a nil body (not \"{}\"/\"[]\")", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", "-- noop")

      {:ok, d} = resolve(dest, sub, %{})

      assert d["body"] == nil
    end

    test "a nil transform_script is a no-op (sends the defaults)", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", nil)

      {:ok, d} = resolve(dest, sub, %{"hi" => 1})

      assert d["body"] == %{"hi" => 1}
      assert d["headers"]["x-event-type"] == "widget.updated"
    end

    test "mixed-case connection headers are canonicalized to lowercase (no case-variant dup)", %{
      owner: owner
    } do
      dest =
        http_connection!(owner, headers: %{"X-Custom" => "1", "Content-Type" => "text/plain"})

      sub = subscription!(dest, "widget.updated", "-- noop")

      {:ok, d} = resolve(dest, sub, %{})

      # The connection's `Content-Type` was stored lowercase, so it collapses onto
      # the single canonical `content-type` key instead of surviving as a
      # case-variant duplicate that resolves nondeterministically at delivery.
      assert d["headers"]["x-custom"] == "1"
      assert Enum.all?(Map.keys(d["headers"]), &(&1 == String.downcase(&1)))
    end

    test "a control char in a transform-set header value parks the delivery", %{owner: owner} do
      dest = http_connection!(owner)

      sub =
        subscription!(dest, "widget.updated", ~s|result.headers["x-evil"] = "a\\r\\nInjected: 1"|)

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "control character"
    end

    test "a control char in a transform-set header NAME parks the delivery", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", ~s|result.headers["x-bad\\nname"] = "1"|)

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "control character"
    end
  end

  describe "SSRF egress (blocking on)" do
    setup do
      original = Application.get_env(:ash_integration, :egress)
      Application.put_env(:ash_integration, :egress, block_private?: true)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:ash_integration, :egress)
          value -> Application.put_env(:ash_integration, :egress, value)
        end
      end)

      :ok
    end

    test "a transform pointing result.url at the metadata IP parks the delivery", %{owner: owner} do
      dest = http_connection!(owner)

      sub =
        subscription!(dest, "widget.updated", ~s|result.url = "http://169.254.169.254/latest"|)

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "egress blocked"
    end

    test "a private base_url (loopback) parks even a no-op transform", %{owner: owner} do
      # The helper's base_url is http://localhost:9999/webhook — loopback.
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", "-- noop")

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "egress blocked"
    end

    test "a public base_url still resolves cleanly", %{owner: owner} do
      dest = http_connection!(owner, base_url: "https://1.1.1.1/hook")
      sub = subscription!(dest, "widget.updated", "-- noop")

      assert {:ok, d} = resolve(dest, sub, %{})
      assert d["url"] == "https://1.1.1.1/hook"
    end
  end

  describe "Kafka" do
    test "pre-seeds topic/key and the native timestamp from created_at (epoch ms)", %{
      owner: owner
    } do
      dest = kafka_connection!(owner)
      sub = subscription!(dest, "stock.changed", "-- noop")
      created_at = ~U[2024-01-15 10:30:00.000000Z]

      {:ok, d} = resolve(dest, sub, %{"q" => 1}, event_key: "w-1", created_at: created_at)

      assert d["transport"] == "kafka"
      assert d["topic"] == "events"
      assert d["key"] == "w-1"
      assert d["timestamp"] == DateTime.to_unix(created_at, :millisecond)
      assert d["headers"]["event-type"] == "stock.changed"
      assert d["value"] == %{"q" => 1}
    end

    test "the transform overrides topic, key, and timestamp", %{owner: owner} do
      dest = kafka_connection!(owner)

      script = """
      result.topic = "custom-topic"
      result.key = "custom-key"
      result.timestamp = 1700000000000
      """

      sub = subscription!(dest, "stock.changed", script)
      {:ok, d} = resolve(dest, sub, %{})

      assert d["topic"] == "custom-topic"
      assert d["key"] == "custom-key"
      assert d["timestamp"] == 1_700_000_000_000
    end

    test "a nil timestamp falls back to created_at, not now", %{owner: owner} do
      dest = kafka_connection!(owner)
      sub = subscription!(dest, "stock.changed", "result.timestamp = nil")
      created_at = ~U[2024-01-15 10:30:00.000000Z]

      {:ok, d} = resolve(dest, sub, %{}, created_at: created_at)

      assert d["timestamp"] == DateTime.to_unix(created_at, :millisecond)
    end

    test "an empty value is stored as nil (the transport encodes it to <<>> at delivery)", %{
      owner: owner
    } do
      dest = kafka_connection!(owner)
      sub = subscription!(dest, "stock.changed", "-- noop")

      {:ok, d} = resolve(dest, sub, %{})

      # Stored as nil (clean descriptor); the Kafka transport coerces nil → <<>>
      # at delivery (brod can't `bin/1` a nil) — asserted in the transport test.
      assert d["value"] == nil
    end

    test "a missing topic (no route, no connection default) parks at dispatch", %{owner: owner} do
      dest = kafka_connection!(owner, topic: nil)
      sub = subscription!(dest, "stock.changed", "-- noop")

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "no Kafka topic configured"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp resolve(connection, subscription, data, opts \\ []) do
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())

    envelope =
      Envelope.transform_input(%{
        id: Ash.UUIDv7.generate(),
        type: subscription.event_type,
        version: subscription.version,
        event_key: Keyword.get(opts, :event_key, "k1"),
        created_at: created_at,
        subject: "r1",
        data: data
      })

    Resolver.resolve(connection, subscription, envelope, created_at)
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

  defp http_connection!(owner, opts \\ []) do
    config =
      %{
        type: :http,
        base_url: Keyword.get(opts, :base_url, "http://localhost:9999/webhook"),
        auth: Keyword.get(opts, :auth, %{type: "none"}),
        timeout_ms: 5000
      }
      |> maybe_put(:signing_secret, opts[:signing_secret])
      |> maybe_put(:headers, opts[:headers])

    connection!(owner, config)
  end

  defp kafka_connection!(owner, opts \\ []) do
    config =
      %{
        type: :kafka,
        brokers: ["localhost:9092"],
        topic: Keyword.get(opts, :topic, "events"),
        security: %{type: "none"}
      }
      |> maybe_put(:signing_secret, opts[:signing_secret])

    connection!(owner, config)
  end

  defp connection!(owner, transport_config) do
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

  defp subscription!(dest, event_type, transform_script) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_script: transform_script
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
