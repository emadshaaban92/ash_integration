defmodule AshIntegration.Transports.KafkaTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Transports.Kafka

  describe "parse_brokers/1" do
    test "parses host:port pairs" do
      assert Kafka.parse_brokers(["kafka1:9092", "kafka2:9093"]) == [
               {~c"kafka1", 9092},
               {~c"kafka2", 9093}
             ]
    end

    test "defaults to port 9092 when port is omitted" do
      assert Kafka.parse_brokers(["kafka1"]) == [{~c"kafka1", 9092}]
    end

    test "handles mixed formats" do
      assert Kafka.parse_brokers(["kafka1:19092", "kafka2"]) == [
               {~c"kafka1", 19092},
               {~c"kafka2", 9092}
             ]
    end

    test "handles empty list" do
      assert Kafka.parse_brokers([]) == []
    end
  end

  describe "partition_for/2" do
    test "returns 0 when partition count is 1" do
      assert Kafka.partition_for("any-key", 1) == 0
      assert Kafka.partition_for("other-key", 1) == 0
    end

    test "returns a value in range 0..count-1" do
      for _ <- 1..100 do
        key = :crypto.strong_rand_bytes(16) |> Base.encode16()
        partition = Kafka.partition_for(key, 10)
        assert partition >= 0 and partition < 10
      end
    end

    test "same key always maps to same partition" do
      p1 = Kafka.partition_for("resource-123", 8)
      p2 = Kafka.partition_for("resource-123", 8)
      assert p1 == p2
    end

    test "distributes keys across partitions" do
      partitions =
        for i <- 1..100 do
          Kafka.partition_for("key-#{i}", 4)
        end
        |> Enum.uniq()

      # With 100 keys and 4 partitions, we should hit at least 2
      assert length(partitions) >= 2
    end
  end

  describe "retryable_error?/1" do
    test "leader_not_available is retryable" do
      assert Kafka.retryable_error?(:leader_not_available)
    end

    test "not_leader_for_partition is retryable" do
      assert Kafka.retryable_error?(:not_leader_for_partition)
    end

    test "request_timed_out is retryable" do
      assert Kafka.retryable_error?(:request_timed_out)
    end

    test "not_enough_replicas is retryable" do
      assert Kafka.retryable_error?(:not_enough_replicas)
    end

    test "connect_error tuples are retryable" do
      assert Kafka.retryable_error?({:connect_error, :econnrefused})
      assert Kafka.retryable_error?({:connect_error, :timeout})
    end

    test "timeout is retryable" do
      assert Kafka.retryable_error?(:timeout)
    end

    test "authorization errors are not retryable" do
      refute Kafka.retryable_error?(:topic_authorization_failed)
    end

    test "unknown errors are not retryable" do
      refute Kafka.retryable_error?(:unknown_error)
      refute Kafka.retryable_error?("some string error")
    end
  end
end
