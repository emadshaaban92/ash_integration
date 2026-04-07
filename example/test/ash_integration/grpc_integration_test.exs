defmodule Example.AshIntegration.GrpcIntegrationTest do
  @moduledoc """
  Integration tests for gRPC transport against a real grpcbin server.

  These tests are excluded by default. Run them with:

      mix test --include grpc_integration

  Requires kong/grpcbin running at grpcbin:9000.
  """

  use Example.DataCase
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers
  import Ecto.Query, warn: false

  @moduletag :grpc_integration

  @grpcbin_endpoint "grpcbin:9000"

  @dummy_proto """
  syntax = "proto3";
  package grpcbin;
  service GRPCBin {
    rpc DummyUnary(DummyMessage) returns (DummyMessage) {}
  }
  message DummyMessage {
    string f_string = 1;
    repeated string f_strings = 2;
    int32 f_int32 = 3;
    bool f_bool = 9;
    int64 f_int64 = 11;
  }
  """

  @addsvc_proto """
  syntax = "proto3";
  package addsvc;
  service Add {
    rpc Sum (SumRequest) returns (SumReply) {}
    rpc Concat (ConcatRequest) returns (ConcatReply) {}
  }
  message SumRequest { int64 a = 1; int64 b = 2; }
  message SumReply { int64 v = 1; string err = 2; }
  message ConcatRequest { string a = 1; string b = 2; }
  message ConcatReply { string v = 1; string err = 2; }
  """

  setup_all do
    # Verify grpcbin is reachable
    case :gen_tcp.connect(~c"grpcbin", 9000, [], 5000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, reason} ->
        raise "grpcbin:9000 is not reachable (#{inspect(reason)}). " <>
                "Start grpcbin with: docker compose up grpcbin"
    end
  end

  describe "low-level gRPC pipeline" do
    test "DummyUnary echoes back the same message" do
      alias AshIntegration.Transports.Grpc.{ProtoRegistry, Channel, Codec}

      {:ok, desc} = ProtoRegistry.get_or_parse("echo-test", @dummy_proto)
      {:ok, input_ctx} = ProtoRegistry.resolve_input_type(desc, "grpcbin.GRPCBin", "DummyUnary")

      payload = %{"f_string" => "integration test", "f_int32" => 99, "f_bool" => true}
      {:ok, encoded} = Codec.encode(payload, input_ctx)

      config = %{
        endpoint: @grpcbin_endpoint,
        security: %Ash.Union{type: :none, value: %AshIntegration.GrpcSecurity.None{}}
      }

      {:ok, channel} = Channel.get_or_connect("echo-test", config)

      {:ok, %{status: 0, body: body}} =
        Channel.unary_call(
          channel,
          "/grpcbin.GRPCBin/DummyUnary",
          encoded,
          [],
          10_000
        )

      # DummyUnary echoes back the same message, so response body should match request
      assert byte_size(body) > 0
      assert body == encoded
    end

    test "addsvc Sum returns correct result" do
      alias AshIntegration.Transports.Grpc.{ProtoRegistry, Channel, Codec}

      {:ok, desc} = ProtoRegistry.get_or_parse("sum-test", @addsvc_proto)
      {:ok, input_ctx} = ProtoRegistry.resolve_input_type(desc, "addsvc.Add", "Sum")

      payload = %{"a" => 17, "b" => 25}
      {:ok, encoded} = Codec.encode(payload, input_ctx)

      config = %{
        endpoint: @grpcbin_endpoint,
        security: %Ash.Union{type: :none, value: %AshIntegration.GrpcSecurity.None{}}
      }

      {:ok, channel} = Channel.get_or_connect("sum-test", config)

      {:ok, %{status: 0, body: body}} =
        Channel.unary_call(channel, "/addsvc.Add/Sum", encoded, [], 10_000)

      # Response should be SumReply{v: 42} = field 1 varint 42 = <<0x08, 0x2A>>
      assert body == <<0x08, 0x2A>>
    end

    test "custom metadata is sent to the server" do
      alias AshIntegration.Transports.Grpc.{ProtoRegistry, Channel, Codec}

      {:ok, desc} = ProtoRegistry.get_or_parse("headers-test", @dummy_proto)
      {:ok, input_ctx} = ProtoRegistry.resolve_input_type(desc, "grpcbin.GRPCBin", "DummyUnary")

      {:ok, encoded} = Codec.encode(%{"f_string" => "hello"}, input_ctx)

      config = %{
        endpoint: @grpcbin_endpoint,
        security: %Ash.Union{type: :none, value: %AshIntegration.GrpcSecurity.None{}}
      }

      {:ok, channel} = Channel.get_or_connect("headers-test", config)

      metadata = [{"x-custom-header", "test-value"}, {"x-another", "123"}]

      {:ok, %{status: 0}} =
        Channel.unary_call(
          channel,
          "/grpcbin.GRPCBin/DummyUnary",
          encoded,
          metadata,
          10_000
        )
    end

    test "connection is reused across multiple calls" do
      alias AshIntegration.Transports.Grpc.{ProtoRegistry, Channel, Codec}

      {:ok, desc} = ProtoRegistry.get_or_parse("reuse-test", @dummy_proto)
      {:ok, input_ctx} = ProtoRegistry.resolve_input_type(desc, "grpcbin.GRPCBin", "DummyUnary")

      {:ok, encoded} = Codec.encode(%{"f_string" => "call"}, input_ctx)

      config = %{
        endpoint: @grpcbin_endpoint,
        security: %Ash.Union{type: :none, value: %AshIntegration.GrpcSecurity.None{}}
      }

      {:ok, channel} = Channel.get_or_connect("reuse-test", config)

      # Make 3 calls on the same connection
      for _i <- 1..3 do
        {:ok, %{status: 0}} =
          Channel.unary_call(
            channel,
            "/grpcbin.GRPCBin/DummyUnary",
            encoded,
            [],
            10_000
          )
      end

      # Second get_or_connect should reuse the same connection
      {:ok, ^channel} = Channel.get_or_connect("reuse-test", config)
    end
  end

  describe "end-to-end delivery via Transport behaviour" do
    test "delivers event to grpcbin and logs success" do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :grpc,
            endpoint: @grpcbin_endpoint,
            service: "grpcbin.GRPCBin",
            method: "DummyUnary",
            proto_definition: @dummy_proto,
            timeout_ms: 10_000
          },
          transform_script: """
          result = {
            f_string = event.data.name,
            f_int32 = 1
          }
          """
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :success
      assert log.response_status == 200
    end

    test "delivers to addsvc Sum and logs success" do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :grpc,
            endpoint: @grpcbin_endpoint,
            service: "addsvc.Add",
            method: "Sum",
            proto_definition: @addsvc_proto,
            timeout_ms: 10_000
          },
          transform_script: """
          result = {
            a = 10,
            b = 32
          }
          """
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :success
      assert log.response_status == 200
    end

    test "custom headers are passed as gRPC metadata" do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :grpc,
            endpoint: @grpcbin_endpoint,
            service: "grpcbin.GRPCBin",
            method: "DummyUnary",
            proto_definition: @dummy_proto,
            timeout_ms: 10_000,
            headers: %{"x-custom" => "value", "x-env" => "test"}
          },
          transform_script: "result = { f_string = \"test\" }"
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :success
    end

    test "signing secret produces x-payload-signature gRPC metadata" do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :grpc,
            endpoint: @grpcbin_endpoint,
            service: "grpcbin.GRPCBin",
            method: "DummyUnary",
            proto_definition: @dummy_proto,
            timeout_ms: 10_000,
            signing_secret: "grpc-test-secret"
          },
          transform_script: "result = { f_string = \"signed\" }"
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :success
    end

    test "invalid service returns non-retryable error" do
      integration =
        create_outbound_integration!(%{
          transport_config: %{
            type: :grpc,
            endpoint: @grpcbin_endpoint,
            service: "nonexistent.Service",
            method: "DoesNotExist",
            proto_definition: """
            syntax = "proto3";
            package nonexistent;
            service Service {
              rpc DoesNotExist (Msg) returns (Msg) {}
            }
            message Msg { string x = 1; }
            """,
            timeout_ms: 10_000
          },
          transform_script: "result = { x = \"test\" }"
        })

      {:ok, integration} = Ash.update(integration, %{}, action: :activate, authorize?: false)

      product = create_product!()
      execute_pipeline!(product)

      [log] = get_delivery_logs(integration.id)
      assert log.status == :failed
      assert log.error_message =~ "gRPC status 12" or log.error_message =~ "UNIMPLEMENTED"
    end
  end
end
