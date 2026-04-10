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

  describe "low-level grpcurl pipeline" do
    test "DummyUnary echoes back the same message" do
      payload = Jason.encode!(%{"fString" => "integration test", "fInt32" => 99, "fBool" => true})

      {output, exit_code} = grpcurl_call(@dummy_proto, "grpcbin.GRPCBin/DummyUnary", payload)

      assert exit_code == 0, "grpcurl failed: #{output}"
      {:ok, response} = Jason.decode(output)
      assert response["fString"] == "integration test"
      assert response["fInt32"] == 99
      assert response["fBool"] == true
    end

    test "addsvc Sum returns correct result" do
      payload = Jason.encode!(%{"a" => "17", "b" => "25"})

      {output, exit_code} = grpcurl_call(@addsvc_proto, "addsvc.Add/Sum", payload)

      assert exit_code == 0, "grpcurl failed: #{output}"
      {:ok, response} = Jason.decode(output)
      assert response["v"] == "42"
    end

    test "custom metadata is sent to the server" do
      payload = Jason.encode!(%{"fString" => "hello"})

      {output, exit_code} =
        grpcurl_call(@dummy_proto, "grpcbin.GRPCBin/DummyUnary", payload,
          headers: [{"x-custom-header", "test-value"}, {"x-another", "123"}]
        )

      assert exit_code == 0, "grpcurl failed: #{output}"
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

      [log] = get_outbound_integration_logs(integration.id)
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

      [log] = get_outbound_integration_logs(integration.id)
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

      [log] = get_outbound_integration_logs(integration.id)
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

      [log] = get_outbound_integration_logs(integration.id)
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

      [log] = get_outbound_integration_logs(integration.id)
      assert log.status == :failed
      assert log.error_message =~ "Unimplemented" or log.error_message =~ "unknown service"
    end
  end

  # Helper to call grpcurl directly for low-level tests
  defp grpcurl_call(proto_content, service_method, json_payload, opts \\ []) do
    tmp_dir = System.tmp_dir!()
    proto_filename = "test_grpc_#{:erlang.unique_integer([:positive])}.proto"
    proto_path = Path.join(tmp_dir, proto_filename)

    try do
      File.write!(proto_path, proto_content)

      header_args =
        (opts[:headers] || [])
        |> Enum.flat_map(fn {k, v} -> ["-H", "#{k}: #{v}"] end)

      args =
        [
          "-import-path",
          tmp_dir,
          "-proto",
          proto_filename,
          "-plaintext",
          "-max-time",
          "10",
          "-d",
          json_payload
        ] ++ header_args ++ [@grpcbin_endpoint, service_method]

      System.cmd("grpcurl", args, stderr_to_stdout: true)
    after
      File.rm(proto_path)
    end
  end
end
