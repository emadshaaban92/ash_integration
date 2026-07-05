defmodule Example.Outbound.TransportKafkaTest do
  @moduledoc """
  Unit tests for the event-first Kafka transport's §7 wire mapping, built without
  a broker via `Kafka.build_message/2` (the pure message builder). Asserts the
  Kafka conventions: BARE (un-prefixed) headers, the partition key is the
  event_key, and the signature header is bare `signature` (not `x-signature`).
  """
  use Example.DataCase, async: false

  alias AshIntegration.Outbound.Wire.Transports.Kafka
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  setup do
    %{owner: create_user!()}
  end

  test "partition key is the event_key and the §7 headers are bare (no x- prefix)", %{
    owner: owner
  } do
    dest = create_kafka_connection!(owner)
    event = create_event!(dest, event_key: "widget-123", data: %{"hello" => "world"})

    {:ok, message} = Kafka.build_message(dest, event)

    # Partition key = event_key (the ordering/compaction key, §5.2/§7).
    assert message.key == "widget-123"
    assert message.value == Jason.encode!(%{"hello" => "world"})
    # Native record timestamp defaulted from the event's created_at (epoch ms),
    # not produce-time.
    assert message.ts == DateTime.to_unix(event.event.created_at, :millisecond)

    headers = Map.new(message.headers)

    # Bare suffixes — NOT x-prefixed (the Kafka convention, §7).
    assert headers["event-type"] == "stock.changed"
    assert headers["event-version"] == "1"
    assert headers["event-id"] == event.event_id
    assert headers["content-type"] == "application/json"
    # Minimal default header set (id/type/version only). event-key is already the
    # native partition key (message.key, asserted above) and created-at the native
    # record ts (message.ts), so neither is duplicated as a header; connection-id
    # is an internal UUID and never sent.
    refute Map.has_key?(headers, "event-key")
    refute Map.has_key?(headers, "created-at")
    refute Map.has_key?(headers, "connection-id")
    # No HTTP-style prefixing leaked in.
    refute Enum.any?(message.headers, fn {k, _} -> String.starts_with?(k, "x-") end)
  end

  test "signature is attached under the bare `signature` header over the post-transform body",
       %{owner: owner} do
    secret = "topsecret"
    dest = create_kafka_connection!(owner, signing_secret: secret)
    event = create_event!(dest, data: %{"a" => 1})

    {:ok, message} = Kafka.build_message(dest, event)
    headers = Map.new(message.headers)

    assert sig = headers["signature"]
    refute Map.has_key?(headers, "x-signature")

    # Recompute the HMAC over "<timestamp>.<body>" and confirm it matches.
    assert %{"t" => ts, "v1" => v1} = parse_signature(sig)

    expected =
      :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{message.value}") |> Base.encode16(case: :lower)

    assert v1 == expected
  end

  test "an empty value is encoded to <<>> (brod can't bin/1 a nil)", %{owner: owner} do
    dest = create_kafka_connection!(owner)
    # No-op transform over empty data → the resolver stores value: nil; the
    # transport must coerce it to the empty binary, not pass nil to brod.
    event = create_event!(dest, data: %{})

    assert is_nil(event.delivery["value"])

    {:ok, message} = Kafka.build_message(dest, event)
    assert message.value == ""
  end

  test "a custom signing `url` placement callback is rejected — Kafka has no URL", %{
    owner: owner
  } do
    signing = %{
      type: "custom",
      secret: "topsecret",
      source: """
      function url(ctx)
        return "https://example.com/elsewhere"
      end
      """
    }

    dest = create_kafka_connection!(owner, signing: signing)
    event = create_event!(dest, data: %{"a" => 1})

    # A pure-config error (Kafka has no URL) fails identically every attempt, so it
    # must be NON-retryable rather than burning the delivery's retry budget.
    assert {:error, %{failure_class: :transport, retryable: false, error_message: message}} =
             Kafka.build_message(dest, event)

    assert message =~ "`url` placement callback does not apply to the Kafka transport"
  end

  test "custom headers pass through but cannot shadow or duplicate bare wire headers", %{
    owner: owner
  } do
    dest =
      create_kafka_connection!(owner,
        headers: %{"x-custom" => "keep-me", "Event-Type" => "spoofed"}
      )

    event = create_event!(dest, data: %{"a" => 1})

    {:ok, message} = Kafka.build_message(dest, event)

    # A non-reserved custom header passes through.
    assert {"x-custom", "keep-me"} in message.headers

    # The reserved bare wire header wins (case-insensitively) and appears once.
    event_type_values =
      for {k, v} <- message.headers, String.downcase(k) == "event-type", do: v

    assert event_type_values == ["stock.changed"]
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp parse_signature(sig) do
    sig
    |> String.split(",")
    |> Map.new(fn part ->
      [k, v] = String.split(part, "=", parts: 2)
      {k, v}
    end)
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

  defp create_kafka_connection!(owner, opts \\ []) do
    kafka =
      %{
        type: :kafka,
        brokers: ["localhost:9092"],
        topic: "events",
        security: %{type: "none"}
      }
      |> then(fn tc ->
        cond do
          signing = opts[:signing] ->
            Map.put(tc, :signing, signing)

          secret = opts[:signing_secret] ->
            Map.put(tc, :signing, %{type: "stripe", secret: secret, header_name: "signature"})

          true ->
            tc
        end
      end)
      |> maybe_put(:headers, opts[:headers])

    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: kafka
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp create_subscription!(dest) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: "stock.changed",
        version: 1,
        transform_source: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Builds a `:scheduled` event whose `delivery` descriptor is RESOLVED through the
  # real `Resolver`, so `build_message/2` is tested against a realistic,
  # signed descriptor. `data:` is the event data (the value before encoding).
  defp create_event!(dest, overrides) do
    overrides = Map.new(overrides)
    sub = Ash.load!(create_subscription!(dest), [:connection], authorize?: false)
    data = Map.get(overrides, :data, %{"x" => 1})
    event_key = Map.get(overrides, :event_key, "widget-123")

    # The immutable Event first — its `created_at` is the occurrence time the wire
    # `created-at` header / Kafka `ts` are sourced from.
    event =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          event_type: "stock.changed",
          version: 1,
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
        type: "stock.changed",
        version: 1,
        event_key: event_key,
        created_at: event.created_at,
        subject: "r1",
        data: data
      })

    {:ok, delivery, _body_hash} =
      AshIntegration.Outbound.Delivery.Resolver.resolve(
        sub.connection,
        sub,
        envelope,
        event.created_at
      )

    delivery_attrs =
      Map.merge(
        %{
          event_id: event.id,
          event_type: "stock.changed",
          version: 1,
          event_key: event_key,
          delivery: delivery,
          state: :scheduled,
          subscription_id: sub.id,
          connection_id: dest.id
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
    |> Ash.load!([:subscription, :connection, :event], authorize?: false)
  end
end
