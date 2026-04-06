defmodule AshIntegration.Transports.Grpc.ProtoValidatorTest do
  use ExUnit.Case, async: false

  alias AshIntegration.Transports.Grpc.{ProtoValidator, ProtoRegistry}

  @simple_proto """
  syntax = "proto3";
  package test;

  service TestService {
    rpc SendEvent (EventRequest) returns (EventResponse);
  }

  message EventRequest {
    string name = 1;
    int32 count = 2;
    bool active = 3;
    double score = 4;
  }

  message EventResponse {
    string result = 1;
  }
  """

  @nested_proto """
  syntax = "proto3";
  package test;

  service TestService {
    rpc CreateOrder (CreateOrderRequest) returns (CreateOrderResponse);
  }

  message Address {
    string street = 1;
    string city = 2;
    int32 zip_code = 3;
  }

  message CreateOrderRequest {
    string order_id = 1;
    Address shipping_address = 2;
    int32 quantity = 3;
  }

  message CreateOrderResponse {
    string status = 1;
  }
  """

  @repeated_proto """
  syntax = "proto3";
  package test;

  service TestService {
    rpc SendBatch (BatchRequest) returns (BatchResponse);
  }

  message Item {
    string id = 1;
    int32 amount = 2;
  }

  message BatchRequest {
    string batch_id = 1;
    repeated string tags = 2;
    repeated Item items = 3;
  }

  message BatchResponse {
    string status = 1;
  }
  """

  @enum_proto """
  syntax = "proto3";
  package test;

  service TestService {
    rpc SetStatus (StatusRequest) returns (StatusResponse);
  }

  enum Priority {
    LOW = 0;
    MEDIUM = 1;
    HIGH = 2;
  }

  message StatusRequest {
    string id = 1;
    Priority priority = 2;
  }

  message StatusResponse {
    string result = 1;
  }
  """

  @grpc_config %{service: "test.TestService", method: "SendEvent"}

  setup_all do
    # ProtoRegistry may already be started by the application supervisor.
    # Only start it if it's not already running.
    case GenServer.whereis(ProtoRegistry) do
      nil -> start_supervised!(ProtoRegistry)
      _pid -> :ok
    end

    :ok
  end

  describe "clean output" do
    test "returns no errors or warnings when all fields present with correct types" do
      output = %{
        "name" => "test_event",
        "count" => 42,
        "active" => true,
        "score" => 9.5
      }

      assert {[], []} = ProtoValidator.validate(output, @simple_proto, @grpc_config)
    end
  end

  describe "missing fields" do
    test "returns warnings for missing fields with default info" do
      output = %{"name" => "test_event"}

      {errors, warnings} = ProtoValidator.validate(output, @simple_proto, @grpc_config)

      assert errors == []
      assert length(warnings) == 3

      assert Enum.any?(
               warnings,
               &(String.contains?(&1, "Missing field") and String.contains?(&1, "count"))
             )

      assert Enum.any?(
               warnings,
               &(String.contains?(&1, "Missing field") and String.contains?(&1, "active"))
             )

      assert Enum.any?(
               warnings,
               &(String.contains?(&1, "Missing field") and String.contains?(&1, "score"))
             )
    end

    test "missing field warnings include default value information" do
      output = %{}

      {_errors, warnings} = ProtoValidator.validate(output, @simple_proto, @grpc_config)

      count_warning = Enum.find(warnings, &String.contains?(&1, "count"))
      assert String.contains?(count_warning, "default to 0")

      active_warning = Enum.find(warnings, &String.contains?(&1, "active"))
      assert String.contains?(active_warning, "default to false")

      score_warning = Enum.find(warnings, &String.contains?(&1, "score"))
      assert String.contains?(score_warning, "default to 0.0")

      name_warning = Enum.find(warnings, &String.contains?(&1, "name"))
      assert String.contains?(name_warning, "default to \"\"")
    end
  end

  describe "extra fields" do
    test "returns warnings for extra fields that will be dropped" do
      output = %{
        "name" => "test_event",
        "count" => 42,
        "active" => true,
        "score" => 9.5,
        "unknown_field" => "hello",
        "another_extra" => 123
      }

      {errors, warnings} = ProtoValidator.validate(output, @simple_proto, @grpc_config)

      assert errors == []

      extra_warnings = Enum.filter(warnings, &String.contains?(&1, "Extra field"))
      assert length(extra_warnings) == 2

      assert Enum.any?(extra_warnings, &String.contains?(&1, "unknown_field"))
      assert Enum.any?(extra_warnings, &String.contains?(&1, "another_extra"))
      assert Enum.all?(extra_warnings, &String.contains?(&1, "will be dropped"))
    end
  end

  describe "type mismatches" do
    test "string where int expected returns error" do
      output = %{
        "name" => "test",
        "count" => "not_a_number",
        "active" => true,
        "score" => 9.5
      }

      {errors, warnings} = ProtoValidator.validate(output, @simple_proto, @grpc_config)

      assert length(errors) == 1
      assert hd(errors) =~ "Type mismatch"
      assert hd(errors) =~ "count"
      assert hd(errors) =~ "string"
      assert warnings == []
    end

    test "int where string expected returns error" do
      output = %{
        "name" => 12345,
        "count" => 42,
        "active" => true,
        "score" => 9.5
      }

      {errors, _warnings} = ProtoValidator.validate(output, @simple_proto, @grpc_config)

      assert length(errors) == 1
      assert hd(errors) =~ "Type mismatch"
      assert hd(errors) =~ "name"
      assert hd(errors) =~ "integer"
    end

    test "scalar where message expected returns error" do
      config = %{service: "test.TestService", method: "CreateOrder"}

      output = %{
        "order_id" => "ord-1",
        "shipping_address" => "123 Main St",
        "quantity" => 5
      }

      {errors, _warnings} = ProtoValidator.validate(output, @nested_proto, config)

      assert length(errors) == 1
      assert hd(errors) =~ "Type mismatch"
      assert hd(errors) =~ "shipping_address"
      assert hd(errors) =~ "expected a map"
    end

    test "boolean where int expected returns error" do
      output = %{
        "name" => "test",
        "count" => true,
        "active" => true,
        "score" => 9.5
      }

      {errors, _warnings} = ProtoValidator.validate(output, @simple_proto, @grpc_config)

      assert length(errors) == 1
      assert hd(errors) =~ "Type mismatch"
      assert hd(errors) =~ "count"
      assert hd(errors) =~ "boolean"
    end
  end

  describe "nested message validation" do
    test "validates nested message fields recursively" do
      config = %{service: "test.TestService", method: "CreateOrder"}

      output = %{
        "order_id" => "ord-1",
        "shipping_address" => %{
          "street" => "123 Main St",
          "city" => "Springfield",
          "zip_code" => 62701
        },
        "quantity" => 5
      }

      assert {[], []} = ProtoValidator.validate(output, @nested_proto, config)
    end

    test "reports type errors in nested message fields" do
      config = %{service: "test.TestService", method: "CreateOrder"}

      output = %{
        "order_id" => "ord-1",
        "shipping_address" => %{
          "street" => "123 Main St",
          "city" => "Springfield",
          "zip_code" => "not_a_number"
        },
        "quantity" => 5
      }

      {errors, _warnings} = ProtoValidator.validate(output, @nested_proto, config)

      assert length(errors) == 1
      assert hd(errors) =~ "zip_code"
      assert hd(errors) =~ "Type mismatch"
    end

    test "reports missing fields in nested messages as warnings" do
      config = %{service: "test.TestService", method: "CreateOrder"}

      output = %{
        "order_id" => "ord-1",
        "shipping_address" => %{
          "street" => "123 Main St"
        },
        "quantity" => 5
      }

      {errors, warnings} = ProtoValidator.validate(output, @nested_proto, config)

      assert errors == []

      missing_nested = Enum.filter(warnings, &String.contains?(&1, "Missing field"))
      assert Enum.any?(missing_nested, &String.contains?(&1, "city"))
      assert Enum.any?(missing_nested, &String.contains?(&1, "zip_code"))
    end
  end

  describe "repeated fields" do
    setup do
      %{config: %{service: "test.TestService", method: "SendBatch"}}
    end

    test "non-list value for repeated field returns error", %{config: config} do
      output = %{
        "batch_id" => "b1",
        "tags" => "single_tag",
        "items" => []
      }

      {errors, _warnings} = ProtoValidator.validate(output, @repeated_proto, config)

      assert length(errors) == 1
      assert hd(errors) =~ "expected a list"
      assert hd(errors) =~ "tags"
    end

    test "wrong element type in repeated field returns error", %{config: config} do
      output = %{
        "batch_id" => "b1",
        "tags" => [123, 456],
        "items" => []
      }

      {errors, _warnings} = ProtoValidator.validate(output, @repeated_proto, config)

      assert length(errors) == 2
      assert Enum.all?(errors, &(&1 =~ "Type mismatch"))
    end

    test "correct list values validate cleanly", %{config: config} do
      output = %{
        "batch_id" => "b1",
        "tags" => ["tag1", "tag2"],
        "items" => [
          %{"id" => "i1", "amount" => 10},
          %{"id" => "i2", "amount" => 20}
        ]
      }

      assert {[], []} = ProtoValidator.validate(output, @repeated_proto, config)
    end

    test "repeated message field with type errors in elements", %{config: config} do
      output = %{
        "batch_id" => "b1",
        "tags" => [],
        "items" => [
          %{"id" => "i1", "amount" => "not_int"},
          %{"id" => 999, "amount" => 10}
        ]
      }

      {errors, _warnings} = ProtoValidator.validate(output, @repeated_proto, config)

      assert length(errors) == 2
      assert Enum.any?(errors, &(&1 =~ "amount"))
      assert Enum.any?(errors, &(&1 =~ "id"))
    end
  end

  describe "enum validation" do
    setup do
      %{config: %{service: "test.TestService", method: "SetStatus"}}
    end

    test "string name is valid for enum field", %{config: config} do
      output = %{"id" => "abc", "priority" => "HIGH"}

      assert {[], []} = ProtoValidator.validate(output, @enum_proto, config)
    end

    test "integer value is valid for enum field", %{config: config} do
      output = %{"id" => "abc", "priority" => 1}

      assert {[], []} = ProtoValidator.validate(output, @enum_proto, config)
    end

    test "boolean is invalid for enum field", %{config: config} do
      output = %{"id" => "abc", "priority" => true}

      {errors, _warnings} = ProtoValidator.validate(output, @enum_proto, config)

      assert length(errors) == 1
      assert hd(errors) =~ "Type mismatch"
      assert hd(errors) =~ "priority"
      assert hd(errors) =~ "boolean"
    end
  end

  describe "float/integer coercion" do
    test "whole float for int field is accepted" do
      output = %{
        "name" => "test",
        "count" => 42.0,
        "active" => true,
        "score" => 9.5
      }

      assert {[], []} = ProtoValidator.validate(output, @simple_proto, @grpc_config)
    end

    test "non-whole float for int field returns error" do
      output = %{
        "name" => "test",
        "count" => 42.5,
        "active" => true,
        "score" => 9.5
      }

      {errors, _warnings} = ProtoValidator.validate(output, @simple_proto, @grpc_config)

      assert length(errors) == 1
      assert hd(errors) =~ "Type mismatch"
      assert hd(errors) =~ "count"
    end

    test "integer is accepted for float field" do
      output = %{
        "name" => "test",
        "count" => 42,
        "active" => true,
        "score" => 10
      }

      assert {[], []} = ProtoValidator.validate(output, @simple_proto, @grpc_config)
    end
  end
end
