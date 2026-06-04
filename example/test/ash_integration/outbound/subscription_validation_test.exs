defmodule Example.Outbound.SubscriptionValidationTest do
  @moduledoc """
  Create/update validation of a subscription's `(event_type, version)` against
  the derived catalog (Task 10, §3.2/§6.1). The example catalog declares
  `widget.updated` v1 and `stock.changed` v1 (see `Example.Catalog.Widget`).
  """
  use Example.DataCase, async: false

  import Example.IntegrationHelpers, only: [create_user!: 0]
  import ExUnit.CaptureLog

  alias AshIntegration.Outbound.Declare.Registry
  alias Example.Outbound.{Connection, Subscription}

  setup do
    %{connection: create_connection!(create_user!())}
  end

  test "accepts a known (event_type, version)", %{connection: dest} do
    assert {:ok, sub} = create_subscription(dest, "widget.updated", 1)
    assert sub.event_type == "widget.updated"
  end

  test "rejects an unknown event type", %{connection: dest} do
    assert {:error, %Ash.Error.Invalid{} = error} = create_subscription(dest, "wigdet.updated", 1)
    assert error_on?(error, :event_type, "is not a known event type")
  end

  test "rejects a known event type at an unsupported version", %{connection: dest} do
    assert {:error, %Ash.Error.Invalid{} = error} = create_subscription(dest, "widget.updated", 2)
    assert error_on?(error, :version, "is not supported")
  end

  test "rejecting on update too: changing to an unknown type fails", %{connection: dest} do
    {:ok, sub} = create_subscription(dest, "widget.updated", 1)

    assert {:error, %Ash.Error.Invalid{}} =
             sub
             |> Ash.Changeset.for_update(:update, %{event_type: "nope.created"},
               authorize?: false
             )
             |> Ash.update(authorize?: false)
  end

  test "health updates skip the catalog check and still succeed", %{connection: dest} do
    {:ok, sub} = create_subscription(dest, "widget.updated", 1)

    # `:suspend` touches neither event_type nor version, so the validation
    # early-outs (no catalog scan) and the action goes through.
    assert {:ok, suspended} =
             sub
             |> Ash.Changeset.for_update(:suspend, %{reason: "test"}, authorize?: false)
             |> Ash.update(authorize?: false)

    assert suspended.suspended
  end

  test "boot check warns about (but does not raise on) an orphaned subscription",
       %{connection: dest} do
    {:ok, _valid} = create_subscription(dest, "widget.updated", 1)

    # Seed bypasses actions/validations, mimicking a row that predates a renamed
    # or removed event — exactly the data-drift the boot check must tolerate.
    orphan =
      Ash.Seed.seed!(Subscription, %{
        connection_id: dest.id,
        event_type: "ghost.event",
        version: 1,
        transform_script: "result = event"
      })

    log =
      capture_log(fn ->
        assert [%{id: id}] = Registry.warn_orphaned_subscriptions()
        assert id == orphan.id
      end)

    assert log =~ "ghost.event"
    assert log =~ orphan.id
  end

  # ── route_config vs. connection-transport-type validation ──────────────────

  test "accepts an HTTP route on a subscription to an HTTP connection", %{connection: dest} do
    assert {:ok, sub} =
             create_route_subscription(dest, %{type: :http, path: "/widgets", method: :patch})

    assert sub.route_config.type == :http
    assert sub.route_config.value.path == "/widgets"
    assert sub.route_config.value.method == :patch
  end

  test "rejects a Kafka route on a subscription to an HTTP connection", %{connection: dest} do
    assert {:error, %Ash.Error.Invalid{} = error} =
             create_route_subscription(dest, %{type: :kafka, topic: "t"})

    assert error_on?(error, :route_config, "transport is http")
  end

  test "rejects an HTTP route on a subscription to a Kafka connection" do
    kafka = create_kafka_connection!(create_user!())

    assert {:error, %Ash.Error.Invalid{} = error} =
             create_route_subscription(kafka, "stock.changed", 1, %{type: :http, path: "/nope"})

    assert error_on?(error, :route_config, "transport is kafka")
  end

  test "accepts a Kafka route (topic) on a subscription to a Kafka connection" do
    kafka = create_kafka_connection!(create_user!())

    assert {:ok, sub} =
             create_route_subscription(kafka, "stock.changed", 1, %{type: :kafka, topic: "orders"})

    assert sub.route_config.type == :kafka
    assert sub.route_config.value.topic == "orders"
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp create_route_subscription(dest, route_config),
    do: create_route_subscription(dest, "widget.updated", 1, route_config)

  defp create_route_subscription(dest, event_type, version, route_config) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: version,
        transform_script: "result = event",
        route_config: route_config
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  defp create_kafka_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "kafka-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :kafka,
          brokers: ["localhost:9092"],
          topic: "default-topic",
          security: %{type: "none"}
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_subscription(dest, event_type, version) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: version,
        transform_script: "result = event"
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
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

  defp error_on?(%Ash.Error.Invalid{errors: errors}, field, message_fragment) do
    Enum.any?(errors, fn err ->
      Map.get(err, :field) == field and
        err |> Map.get(:message, "") |> to_string() =~ message_fragment
    end)
  end
end
