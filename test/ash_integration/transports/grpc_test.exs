defmodule AshIntegration.Transports.GrpcTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Transports.Grpc

  describe "grpc_status_to_http/1" do
    test "OK (0) maps to 200" do
      assert Grpc.grpc_status_to_http(0) == 200
    end

    test "DEADLINE_EXCEEDED (4) maps to 504" do
      assert Grpc.grpc_status_to_http(4) == 504
    end

    test "RESOURCE_EXHAUSTED (8) maps to 429" do
      assert Grpc.grpc_status_to_http(8) == 429
    end

    test "UNAVAILABLE (14) maps to 503" do
      assert Grpc.grpc_status_to_http(14) == 503
    end

    test "INVALID_ARGUMENT (3) maps to 400" do
      assert Grpc.grpc_status_to_http(3) == 400
    end

    test "NOT_FOUND (5) maps to 404" do
      assert Grpc.grpc_status_to_http(5) == 404
    end

    test "PERMISSION_DENIED (7) maps to 403" do
      assert Grpc.grpc_status_to_http(7) == 403
    end

    test "UNIMPLEMENTED (12) maps to 501" do
      assert Grpc.grpc_status_to_http(12) == 501
    end

    test "UNAUTHENTICATED (16) maps to 401" do
      assert Grpc.grpc_status_to_http(16) == 401
    end

    test "unknown status codes default to 500" do
      assert Grpc.grpc_status_to_http(1) == 500
      assert Grpc.grpc_status_to_http(2) == 500
      assert Grpc.grpc_status_to_http(99) == 500
    end

    test "retryable classification: 5xx statuses are retryable" do
      # UNAVAILABLE, DEADLINE_EXCEEDED map to >= 500
      assert Grpc.grpc_status_to_http(14) >= 500
      assert Grpc.grpc_status_to_http(4) >= 500

      # Client errors are not retryable
      assert Grpc.grpc_status_to_http(3) < 500
      assert Grpc.grpc_status_to_http(5) < 500
      assert Grpc.grpc_status_to_http(7) < 500
      assert Grpc.grpc_status_to_http(16) < 500
    end
  end
end
