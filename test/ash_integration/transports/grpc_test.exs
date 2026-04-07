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

  describe "classify_error/1" do
    test "connection refused is retryable" do
      {retryable, type} =
        Grpc.classify_error(
          ~s(Failed to dial target host "localhost:50051": connection error: desc = "transport: error while dialing: dial tcp [::1]:50051: connect: connection refused")
        )

      assert retryable == true
      assert type == :connection_refused
    end

    test "context deadline exceeded is retryable" do
      {retryable, type} =
        Grpc.classify_error(
          ~s(Failed to dial target host "192.0.2.1:50051": context deadline exceeded)
        )

      assert retryable == true
      assert type == :timeout
    end

    test "gRPC Unavailable is retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: Unavailable\n  Message: connection error")

      assert retryable == true
      assert type == :unavailable
    end

    test "gRPC ResourceExhausted is retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: ResourceExhausted\n  Message: rate limited")

      assert retryable == true
      assert type == :rate_limited
    end

    test "gRPC DeadlineExceeded is retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: DeadlineExceeded\n  Message: timeout")

      assert retryable == true
      assert type == :timeout
    end

    test "gRPC Internal is retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: Internal\n  Message: internal error")

      assert retryable == true
      assert type == :internal
    end

    test "gRPC NotFound is not retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: NotFound\n  Message: resource not found")

      assert retryable == false
      assert type == :not_found
    end

    test "gRPC InvalidArgument is not retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: InvalidArgument\n  Message: bad request")

      assert retryable == false
      assert type == :invalid_argument
    end

    test "gRPC PermissionDenied is not retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: PermissionDenied\n  Message: forbidden")

      assert retryable == false
      assert type == :permission_denied
    end

    test "gRPC Unauthenticated is not retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: Unauthenticated\n  Message: invalid token")

      assert retryable == false
      assert type == :unauthenticated
    end

    test "gRPC Unimplemented is not retryable" do
      {retryable, type} =
        Grpc.classify_error("ERROR:\n  Code: Unimplemented\n  Message: not implemented")

      assert retryable == false
      assert type == :unimplemented
    end

    test "proto processing error is not retryable" do
      {retryable, type} =
        Grpc.classify_error(
          "Failed to process proto source files.: could not parse: bad.proto:1:1: syntax error"
        )

      assert retryable == false
      assert type == :proto_error
    end

    test "unknown error is not retryable" do
      {retryable, type} = Grpc.classify_error("some unexpected error output")

      assert retryable == false
      assert type == :unknown
    end
  end
end
