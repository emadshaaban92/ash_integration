defmodule AshIntegration.Transports.Grpc.CodecTest do
  use ExUnit.Case, async: false

  alias AshIntegration.Transports.Grpc.{Codec, ProtoRegistry}

  @scalar_proto """
  syntax = "proto3";
  package test;

  service TestService {
    rpc SendScalar (ScalarMessage) returns (ScalarMessage);
  }

  message ScalarMessage {
    string name = 1;
    int32 age = 2;
    bool active = 3;
    double score = 4;
    float ratio = 5;
  }
  """

  @nested_proto """
  syntax = "proto3";
  package test;

  service TestService {
    rpc SendNested (OuterMessage) returns (OuterMessage);
  }

  message InnerMessage {
    string label = 1;
    int32 count = 2;
  }

  message OuterMessage {
    string title = 1;
    InnerMessage inner = 2;
  }
  """

  @repeated_proto """
  syntax = "proto3";
  package test;

  service TestService {
    rpc SendRepeated (RepeatedMessage) returns (RepeatedMessage);
  }

  message RepeatedMessage {
    repeated string tags = 1;
    repeated int32 scores = 2;
  }
  """

  setup_all do
    case ProtoRegistry.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp resolve_input(proto, service, method) do
    {:ok, descriptor_set} = ProtoRegistry.get_or_parse("test-integration", proto)
    {:ok, context} = ProtoRegistry.resolve_input_type(descriptor_set, service, method)
    context
  end

  describe "scalar types" do
    test "encodes string, int32, bool, double, and float fields" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{
        "name" => "Alice",
        "age" => 30,
        "active" => true,
        "score" => 98.5,
        "ratio" => 0.75
      }

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert byte_size(binary) > 0
    end

    test "encodes integer values correctly" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{"age" => 42}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert byte_size(binary) > 0
    end

    test "encodes boolean true" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{"active" => true}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
    end

    test "encodes boolean false (proto3 default, may omit)" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{"active" => false}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
    end

    test "encodes string field" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{"name" => "Hello World"}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      # The encoded binary should contain the string value
      assert String.contains?(binary, "Hello World")
    end
  end

  describe "nested messages" do
    test "encodes a message with a nested message field" do
      context = resolve_input(@nested_proto, "TestService", "SendNested")

      payload = %{
        "title" => "Parent",
        "inner" => %{
          "label" => "Child",
          "count" => 5
        }
      }

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert byte_size(binary) > 0
      # Both string values should appear in the binary
      assert String.contains?(binary, "Parent")
      assert String.contains?(binary, "Child")
    end

    test "encodes with nil nested field (omitted)" do
      context = resolve_input(@nested_proto, "TestService", "SendNested")

      payload = %{"title" => "Solo"}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert String.contains?(binary, "Solo")
    end
  end

  describe "repeated fields" do
    test "encodes repeated string fields" do
      context = resolve_input(@repeated_proto, "TestService", "SendRepeated")

      payload = %{"tags" => ["alpha", "beta", "gamma"]}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert String.contains?(binary, "alpha")
      assert String.contains?(binary, "beta")
      assert String.contains?(binary, "gamma")
    end

    test "encodes packed repeated int32 fields" do
      context = resolve_input(@repeated_proto, "TestService", "SendRepeated")

      payload = %{"scores" => [10, 20, 30]}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert byte_size(binary) > 0
    end

    test "encodes empty repeated fields" do
      context = resolve_input(@repeated_proto, "TestService", "SendRepeated")

      payload = %{"tags" => [], "scores" => []}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
    end
  end

  describe "missing fields (proto3 defaults)" do
    test "encodes an empty payload (all fields use defaults)" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert binary == <<>>
    end

    test "encodes with only some fields present" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{"name" => "Bob"}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert String.contains?(binary, "Bob")
    end
  end

  describe "empty payload" do
    test "encodes empty map to empty binary" do
      context = resolve_input(@nested_proto, "TestService", "SendNested")

      assert {:ok, binary} = Codec.encode(%{}, context)
      assert binary == <<>>
    end
  end

  describe "error cases" do
    test "returns error tuple when encoding fails with bad data" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      # A list where a scalar string is expected should cause an encoding failure
      payload = %{"name" => {:not, :a, :string}}

      assert {:error, message} = Codec.encode(payload, context)
      assert is_binary(message)
      assert message =~ "Protobuf encoding failed"
    end
  end

  describe "atom keys in payload" do
    test "encodes payload with atom keys" do
      context = resolve_input(@scalar_proto, "TestService", "SendScalar")

      payload = %{name: "AtomKey", age: 25}

      assert {:ok, binary} = Codec.encode(payload, context)
      assert is_binary(binary)
      assert String.contains?(binary, "AtomKey")
    end
  end
end
