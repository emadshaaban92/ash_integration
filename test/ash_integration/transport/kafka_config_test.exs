defmodule AshIntegration.Transport.KafkaConfigTest do
  # Broker host:port shape is validated AT SAVE TIME so a malformed entry (a bad
  # port) can't sit on a connection and crash `Utils.parse_brokers/1` at delivery.
  use ExUnit.Case, async: true

  alias AshIntegration.Transport.KafkaConfig
  alias AshIntegration.Transport.Utils

  defp create(brokers) do
    KafkaConfig
    |> Ash.Changeset.for_create(:create, %{brokers: brokers})
    |> Ash.create()
  end

  describe "brokers save-time validation" do
    test "a host without a port is accepted (defaults to 9092 at parse time)" do
      assert {:ok, %KafkaConfig{brokers: ["kafka.internal"]}} = create(["kafka.internal"])
    end

    test "a host:port with an integer port is accepted" do
      assert {:ok, %KafkaConfig{}} = create(["kafka.internal:9092", "kafka-2.internal:9093"])
    end

    test "a non-integer port is rejected on create" do
      assert {:error, %Ash.Error.Invalid{} = error} = create(["kafka.internal:abc"])
      assert Exception.message(error) =~ "kafka.internal:abc"
    end

    test "an out-of-range port is rejected on create" do
      assert {:error, %Ash.Error.Invalid{}} = create(["kafka.internal:99999"])
      assert {:error, %Ash.Error.Invalid{}} = create(["kafka.internal:0"])
    end

    test "an extra colon (host:1:2) is rejected on create" do
      assert {:error, %Ash.Error.Invalid{}} = create(["kafka.internal:1:2"])
    end

    test "an empty host is rejected on create" do
      assert {:error, %Ash.Error.Invalid{}} = create([":9092"])
      assert {:error, %Ash.Error.Invalid{}} = create([""])
    end

    test "one bad entry among good ones rejects the whole list" do
      assert {:error, %Ash.Error.Invalid{}} =
               create(["good.internal:9092", "bad.internal:nope"])
    end

    test "an accepted broker parses without raising, a rejected one would have crashed" do
      assert {:ok, %KafkaConfig{brokers: brokers}} = create(["kafka.internal:9092"])
      assert Utils.parse_brokers(brokers) == [{~c"kafka.internal", 9092}]

      # This is exactly the input the validation now blocks: parse_brokers would
      # raise ArgumentError at delivery time on it.
      assert_raise ArgumentError, fn -> Utils.parse_brokers(["kafka.internal:abc"]) end
    end
  end
end
