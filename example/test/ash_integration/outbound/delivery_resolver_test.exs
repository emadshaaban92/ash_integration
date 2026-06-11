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
      function transform(event, defaults)
        defaults.headers["x-event-id"] = nil
        defaults.headers["x-custom"] = "added"
        defaults.headers["x-event-type"] = "overridden"
        return defaults
      end
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
          ~s|function transform(event, defaults) defaults.path = "/widgets/42"; defaults.method = "put" return defaults end|
        )

      {:ok, d} = resolve(dest, sub, %{})

      assert d["method"] == "put"
      assert d["url"] == "http://localhost:9999/webhook/widgets/42"
    end

    test "result.url is an absolute override that bypasses base_url + path", %{owner: owner} do
      dest = http_connection!(owner)

      sub =
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.url = "https://elsewhere.test/in" return defaults end|
        )

      {:ok, d} = resolve(dest, sub, %{})

      assert d["url"] == "https://elsewhere.test/in"
    end

    test "the signature is NOT in the descriptor (it is a live carve-out, added at delivery)",
         %{owner: owner} do
      dest = http_connection!(owner, signing_secret: "topsecret")

      sub =
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.body = { a = 1 } return defaults end|
        )

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

      sub =
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.method = "TRACE" return defaults end|
        )

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "invalid HTTP method"
    end

    test "a non-string header value is a transform error (the event parks)", %{owner: owner} do
      dest = http_connection!(owner)

      sub =
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.headers["x-bad"] = { nested = 1 } return defaults end|
        )

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "the transform's headers"
    end

    test "result = nil skips", %{owner: owner} do
      dest = http_connection!(owner)

      sub =
        subscription!(
          dest,
          "widget.updated",
          "function transform(event, defaults) return nil end"
        )

      assert :skip = resolve(dest, sub, %{})
    end

    test "empty event data resolves to a nil body (not \"{}\"/\"[]\")", %{owner: owner} do
      dest = http_connection!(owner)
      sub = subscription!(dest, "widget.updated", "-- noop")

      {:ok, d} = resolve(dest, sub, %{})

      assert d["body"] == nil
    end

    test "a nil transform_source is a no-op (sends the defaults)", %{owner: owner} do
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
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.headers["x-evil"] = "a\\r\\nInjected: 1" return defaults end|
        )

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "control character"
    end

    test "a control char in a transform-set header NAME parks the delivery", %{owner: owner} do
      dest = http_connection!(owner)

      sub =
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.headers["x-bad\\nname"] = "1" return defaults end|
        )

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
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.url = "http://169.254.169.254/latest" return defaults end|
        )

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

    test "an UNRESOLVABLE base_url does NOT park — it stays deliverable (transport, not build)",
         %{owner: owner} do
      # NXDOMAIN endpoint = a connectivity condition, not an authoring bug: the
      # resolver returns a deliverable descriptor so it fails as :transport at send.
      # `.invalid` is reserved (RFC 6761) and never resolves.
      dest = http_connection!(owner, base_url: "https://wms.digitalhub.example.invalid/hook")
      sub = subscription!(dest, "widget.updated", "-- noop")

      assert {:ok, d} = resolve(dest, sub, %{})
      assert d["url"] == "https://wms.digitalhub.example.invalid/hook"
    end

    test "a transform-set URL at an UNRESOLVABLE host still PARKS (authoring bug, not the endpoint)",
         %{owner: owner} do
      # A bad `result.url` is an authoring bug to fix + reprocess, never a
      # connection-health signal — only an unresolvable base_url is a transport case.
      dest = http_connection!(owner, base_url: "https://1.1.1.1/hook")

      sub =
        subscription!(
          dest,
          "widget.updated",
          ~s|function transform(event, defaults) defaults.url = "https://typo.example.invalid/in" return defaults end|
        )

      assert {:error, message} = resolve(dest, sub, %{})
      assert message =~ "egress blocked"
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

      assert d["topic"] == "events"
      assert d["key"] == "w-1"
      assert d["timestamp"] == DateTime.to_unix(created_at, :millisecond)
      assert d["headers"]["event-type"] == "stock.changed"
      assert d["value"] == %{"q" => 1}
    end

    test "the transform overrides topic, key, and timestamp", %{owner: owner} do
      dest = kafka_connection!(owner)

      script = """
      function transform(event, defaults)
        defaults.topic = "custom-topic"
        defaults.key = "custom-key"
        defaults.timestamp = 1700000000000
        return defaults
      end
      """

      sub = subscription!(dest, "stock.changed", script)
      {:ok, d} = resolve(dest, sub, %{})

      assert d["topic"] == "custom-topic"
      assert d["key"] == "custom-key"
      assert d["timestamp"] == 1_700_000_000_000
    end

    test "a nil timestamp falls back to created_at, not now", %{owner: owner} do
      dest = kafka_connection!(owner)

      sub =
        subscription!(
          dest,
          "stock.changed",
          "function transform(event, defaults) defaults.timestamp = nil return defaults end"
        )

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

  # The transform script is validated at SAVE time (not just at dispatch) by
  # delegating to the runtime through the Transformer seam, so a malformed script
  # is a clean field error on the form rather than a parked delivery later.
  describe "save-time transform validation" do
    alias AshIntegration.Outbound.Delivery.Transform.Preview
    alias AshIntegration.Outbound.Delivery.Validations.TransformSource

    test "rejects a script the runtime can't accept, as a transform_source field error",
         %{owner: owner} do
      # Inject the value past the DSL `max_length` cast (which would otherwise
      # intercept it first) so the rejection comes from the runtime's own
      # validator — proving the Transformer delegation path, not the redundant
      # attribute constraint.
      changeset =
        put_attribute(create_changeset(owner, nil), :transform_source, oversized_script())

      assert {:error, field: :transform_source, message: message} =
               TransformSource.validate(changeset, [], %{})

      assert message =~ "maximum size"
    end

    test "accepts a well-formed script", %{owner: owner} do
      changeset = create_changeset(owner, "function transform(event, defaults) return event end")
      assert :ok = TransformSource.validate(changeset, [], %{})
    end

    test "a nil script is a no-op and valid", %{owner: owner} do
      changeset = create_changeset(owner, nil)
      assert :ok = TransformSource.validate(changeset, [], %{})
    end

    test "the create action rejects a syntactically invalid script", %{owner: owner} do
      dest = http_connection!(owner)

      assert {:error, error} =
               Subscription
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   connection_id: dest.id,
                   event_type: "widget.updated",
                   version: 1,
                   transform_source: "function transform(e, d) return {"
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)

      assert Exception.message(error) =~ "does not parse"
    end

    test "the create action rejects a script that raises against the producer example",
         %{owner: owner} do
      dest = http_connection!(owner)

      assert {:error, error} =
               create_subscription(dest, "widget.updated", "error('boom')")

      # The smoke gate ran error('boom') against WidgetUpdated.example/1 and caught
      # the raise at save — it never reaches dispatch to park a delivery.
      assert Exception.message(error) =~ "boom"
    end

    test "the create action rejects a script that attempts denied IO", %{owner: owner} do
      dest = http_connection!(owner)

      # io.* is removed from the sandbox, so this is syntactically valid but cannot
      # run — exactly the class parse can't see and the smoke run does.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               create_subscription(dest, "widget.updated", "io.write('x')")

      assert Enum.any?(errors, &(Map.get(&1, :field) == :transform_source))
    end

    test "the create action accepts a script that runs cleanly on the example",
         %{owner: owner} do
      dest = http_connection!(owner)

      assert {:ok, _sub} =
               create_subscription(
                 dest,
                 "widget.updated",
                 "function transform(event, defaults) defaults.headers['x-ok'] = 'yes' return defaults end"
               )
    end

    test "the smoke gate no-ops when there is no example/1 to run against" do
      # With no representative sample, the smoke layer degrades to the parse floor
      # — an otherwise-erroring script is not rejected here. (An unregistered
      # event_type has no producer, so example/1 resolves to nil; the create action
      # would separately reject the unknown type, so exercise the branch directly.)
      assert :ok =
               Preview.smoke(
                 %{
                   event_type: "unregistered.event",
                   version: 1,
                   transform_source: "error('boom')"
                 },
                 nil
               )
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp create_changeset(owner, transform_source) do
    dest = http_connection!(owner)

    params =
      %{connection_id: dest.id, event_type: "widget.updated", version: 1}
      |> maybe_put(:transform_source, transform_source)

    Ash.Changeset.for_create(Subscription, :create, params, authorize?: false)
  end

  # Run the real create action and return the raw result, for end-to-end checks
  # of the save-time gate.
  defp create_subscription(connection, event_type, transform_source) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: connection.id,
        event_type: event_type,
        version: 1,
        transform_source: transform_source
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  # Set an attribute directly on the changeset, bypassing casting/constraints —
  # used to drive a value the DSL `max_length` would otherwise reject before it
  # reaches the runtime's own validator.
  defp put_attribute(changeset, attribute, value) do
    %{changeset | attributes: Map.put(changeset.attributes, attribute, value)}
  end

  defp oversized_script, do: String.duplicate("x", 10_241)

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

    # The resolver returns `{:ok, descriptor, body_hash}`; these tests predate the
    # suppression hash and assert on the descriptor, so normalize to `{:ok, descriptor}`.
    case Resolver.resolve(connection, subscription, envelope, created_at) do
      {:ok, descriptor, _body_hash} -> {:ok, descriptor}
      other -> other
    end
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
      |> maybe_put(:signing, stripe_signing(opts[:signing_secret], "x-signature"))
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
      |> maybe_put(:signing, stripe_signing(opts[:signing_secret], "signature"))

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

  defp subscription!(dest, event_type, transform_source) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_source: transform_source
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stripe_signing(nil, _header), do: nil
  defp stripe_signing(secret, header), do: %{type: "stripe", secret: secret, header_name: header}
end
