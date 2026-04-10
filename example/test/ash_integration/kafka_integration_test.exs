defmodule Example.AshIntegration.KafkaIntegrationTest do
  @moduledoc """
  Integration tests for Kafka transport against a real Redpanda/Kafka broker.

  These tests are excluded by default. Run them with:

      mix test --include kafka_integration

  Requires a Kafka-compatible broker (e.g. Redpanda) at redpanda:9092.
  """

  use Example.DataCase
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers
  import Ecto.Query, warn: false

  @topic "kafka-integration-test"
  @brokers [{~c"redpanda", 9092}]

  @moduletag :kafka_integration

  setup_all do
    {:ok, _} = Application.ensure_all_started(:brod)

    # Ensure topic exists via direct connection
    {:ok, conn} = :kpro.connect_any(@brokers, [])

    :kpro.request_sync(
      conn,
      :kpro_req_lib.create_topics(
        0,
        [%{name: @topic, num_partitions: 3, replication_factor: 1, assignments: [], configs: []}],
        %{timeout: 5000}
      ),
      5000
    )

    :kpro.close_connection(conn)
    :ok
  end

  setup do
    # Record the current high-water offsets so we only read new messages
    offsets =
      for partition <- 0..2, into: %{} do
        case :brod.resolve_offset(@brokers, @topic, partition, :latest, []) do
          {:ok, offset} -> {partition, offset}
          _ -> {partition, 0}
        end
      end

    %{start_offsets: offsets}
  end

  defp fetch_message(partition, start_offset, target_offset) do
    {:ok, {_hw, messages}} = :brod.fetch(@brokers, @topic, partition, start_offset)

    Enum.find(messages, fn {:kafka_message, offset, _key, _val, _ts_type, _ts, _headers} ->
      offset == target_offset
    end)
  end

  describe "end-to-end Kafka delivery" do
    test "produces a message to Kafka with correct key, headers, and payload", %{
      start_offsets: start_offsets
    } do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :kafka,
            brokers: ["redpanda:9092"],
            topic: @topic
          }
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      # Find the delivery log
      [log] = get_outbound_integration_logs(integration.id)
      assert log.status == :success
      assert is_integer(log.kafka_offset)
      assert is_integer(log.kafka_partition)

      # Read the message from Kafka
      message =
        fetch_message(log.kafka_partition, start_offsets[log.kafka_partition], log.kafka_offset)

      assert message != nil

      {:kafka_message, _offset, key, value, _ts_type, _ts, headers} = message

      # Key is the resource_id (product UUID)
      assert key == to_string(product.id)

      # Payload is valid JSON with event data
      payload = Jason.decode!(value)
      assert payload["action"] == "create"
      assert payload["data"]["id"] == to_string(product.id)
      assert payload["data"]["name"] == product.name

      # Headers contain event_id and integration_id
      headers_map = Map.new(headers)
      assert Map.has_key?(headers_map, "event_id")
      assert headers_map["integration_id"] == to_string(integration.id)
    end

    test "custom headers are included in Kafka message headers", %{
      start_offsets: start_offsets
    } do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :kafka,
            brokers: ["redpanda:9092"],
            topic: @topic,
            headers: %{"x-source" => "test", "x-env" => "ci"}
          }
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      [log] = get_outbound_integration_logs(integration.id)
      assert log.status == :success

      {:kafka_message, _, _key, _value, _ts_type, _ts, headers} =
        fetch_message(log.kafka_partition, start_offsets[log.kafka_partition], log.kafka_offset)

      headers_map = Map.new(headers)
      assert headers_map["x-source"] == "test"
      assert headers_map["x-env"] == "ci"
    end

    test "signing secret produces x-payload-signature Kafka header", %{
      start_offsets: start_offsets
    } do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :kafka,
            brokers: ["redpanda:9092"],
            topic: @topic,
            signing_secret: "my-test-secret"
          }
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      [log] = get_outbound_integration_logs(integration.id)
      assert log.status == :success

      {:kafka_message, _, _key, value, _ts_type, _ts, headers} =
        fetch_message(log.kafka_partition, start_offsets[log.kafka_partition], log.kafka_offset)

      headers_map = Map.new(headers)
      assert sig = headers_map["x-payload-signature"]
      assert sig =~ ~r/^t=\d+,v1=[0-9a-f]+$/

      # Verify the signature is correct
      [_, timestamp, hex_digest] = Regex.run(~r/^t=(\d+),v1=([0-9a-f]+)$/, sig)

      expected =
        :crypto.mac(:hmac, :sha256, "my-test-secret", "#{timestamp}.#{value}")
        |> Base.encode16(case: :lower)

      assert hex_digest == expected
    end

    test "messages for the same resource land on the same partition" do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :kafka,
            brokers: ["redpanda:9092"],
            topic: @topic
          },
          actions: ["create", "update"]
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      # Update the same product
      Ash.update!(product, %{name: "Updated Name"}, action: :update, authorize?: false)
      execute_pipeline!(product)

      logs = get_outbound_integration_logs(integration.id)
      partitions = Enum.map(logs, & &1.kafka_partition) |> Enum.uniq()
      assert length(partitions) == 1, "Expected all messages for same resource on same partition"
    end
  end
end
