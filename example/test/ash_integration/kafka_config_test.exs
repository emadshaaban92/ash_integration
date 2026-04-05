defmodule Example.AshIntegration.KafkaConfigTest do
  use Example.DataCase

  import Example.IntegrationHelpers

  defp kafka_transport_config(overrides \\ %{}) do
    Map.merge(
      %{
        type: :kafka,
        brokers: ["localhost:9092"],
        topic: "test-events"
      },
      overrides
    )
  end

  describe "creating integration with Kafka transport" do
    test "creates successfully with minimal config (defaults to none)" do
      integration =
        create_outbound_integration!(%{
          transport_config: kafka_transport_config()
        })

      assert %Ash.Union{type: :kafka, value: config} = integration.transport_config
      assert config.brokers == ["localhost:9092"]
      assert config.topic == "test-events"
      assert config.acks == :all
      assert config.delivery_timeout_ms == 30_000
      assert config.headers == %{}
      assert %Ash.Union{type: :none} = config.security
    end

    test "creates with SASL + TLS security" do
      integration =
        create_outbound_integration!(%{
          transport_config:
            kafka_transport_config(%{
              brokers: ["broker1:9092", "broker2:9093"],
              topic: "my-topic",
              acks: :leader,
              delivery_timeout_ms: 10_000,
              headers: %{"x-source" => "test"},
              signing_secret: "my-secret",
              security: %{
                type: "sasl_tls",
                mechanism: :plain,
                username: "user",
                password: "pass"
              }
            })
        })

      assert %Ash.Union{type: :kafka, value: config} = integration.transport_config
      assert config.brokers == ["broker1:9092", "broker2:9093"]
      assert config.topic == "my-topic"
      assert config.acks == :leader
      assert config.delivery_timeout_ms == 10_000
      assert config.headers == %{"x-source" => "test"}
      assert %Ash.Union{type: :sasl_tls, value: sec} = config.security
      assert sec.mechanism == :plain
      assert sec.username == "user"
    end

    test "creates with TLS only" do
      integration =
        create_outbound_integration!(%{
          transport_config: kafka_transport_config(%{security: %{type: "tls"}})
        })

      assert %Ash.Union{type: :kafka, value: config} = integration.transport_config
      assert %Ash.Union{type: :tls} = config.security
    end

    test "creates with SASL (no TLS)" do
      integration =
        create_outbound_integration!(%{
          transport_config:
            kafka_transport_config(%{
              security: %{
                type: "sasl",
                mechanism: :scram_sha_256,
                username: "user",
                password: "pass"
              }
            })
        })

      assert %Ash.Union{type: :kafka, value: config} = integration.transport_config
      assert %Ash.Union{type: :sasl, value: sec} = config.security
      assert sec.mechanism == :scram_sha_256
      assert sec.username == "user"
    end
  end

  describe "validation" do
    test "requires brokers" do
      assert {:error, _} =
               Example.Integration.OutboundIntegration
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "kafka-no-brokers",
                   resource: "product",
                   actions: ["create"],
                   schema_version: 1,
                   transport_config: %{type: :kafka, brokers: [], topic: "test"},
                   transform_script: "result = event",
                   owner_id: create_user!().id
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end

    test "requires topic" do
      assert {:error, _} =
               Example.Integration.OutboundIntegration
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "kafka-no-topic",
                   resource: "product",
                   actions: ["create"],
                   schema_version: 1,
                   transport_config: %{type: :kafka, brokers: ["localhost:9092"]},
                   transform_script: "result = event",
                   owner_id: create_user!().id
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end

    test "rejects delivery_timeout_ms below 1000" do
      assert {:error, _} =
               Example.Integration.OutboundIntegration
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "kafka-low-timeout",
                   resource: "product",
                   actions: ["create"],
                   schema_version: 1,
                   transport_config: kafka_transport_config(%{delivery_timeout_ms: 500}),
                   transform_script: "result = event",
                   owner_id: create_user!().id
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end

    test "rejects invalid acks value" do
      assert {:error, _} =
               Example.Integration.OutboundIntegration
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "kafka-bad-acks",
                   resource: "product",
                   actions: ["create"],
                   schema_version: 1,
                   transport_config: kafka_transport_config(%{acks: :invalid}),
                   transform_script: "result = event",
                   owner_id: create_user!().id
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "transport config union" do
    test "module_for resolves to Kafka transport" do
      assert AshIntegration.Transport.module_for(:kafka) == AshIntegration.Transports.Kafka
    end

    test "HTTP integrations still work" do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :http,
            url: "http://localhost:9999/webhook",
            auth: %{type: "none"},
            timeout_ms: 5000
          }
        })

      assert %Ash.Union{type: :http} = integration.transport_config
    end
  end
end
