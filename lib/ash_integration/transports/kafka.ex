defmodule AshIntegration.Transports.Kafka do
  @moduledoc false

  @behaviour AshIntegration.Transport

  require Logger

  alias AshIntegration.KafkaClientManager

  @impl true
  def deliver(outbound_integration, event_id, resource_id, payload) do
    unless AshIntegration.Transport.available?(:kafka) do
      {:error,
       %{
         error_message:
           "Kafka transport is not available. Add {:brod, \"~> 4.0\"} to your dependencies.",
         retryable: false
       }}
    else
      do_deliver(outbound_integration, event_id, resource_id, payload)
    end
  end

  defp do_deliver(outbound_integration, event_id, resource_id, payload) do
    %Ash.Union{type: :kafka, value: config} = outbound_integration.transport_config
    json_payload = Jason.encode!(payload)

    brokers = parse_brokers(config.brokers)
    client_id = KafkaClientManager.client_id_for(outbound_integration.id)
    client_config = build_client_config(config)
    partition_key = to_string(resource_id)

    custom_headers =
      Enum.map(config.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    headers =
      [{"event_id", event_id}, {"integration_id", to_string(outbound_integration.id)}] ++
        custom_headers ++
        AshIntegration.PayloadSigning.signature_headers(config, json_payload)

    message = %{
      key: partition_key,
      value: json_payload,
      headers: headers
    }

    producer_config = [required_acks: acks_to_brod(config.acks)]

    with :ok <-
           KafkaClientManager.ensure_client(
             outbound_integration.id,
             brokers,
             client_config,
             config.topic,
             producer_config
           ),
         partition_count <- resolve_partition_count(client_id, config.topic),
         partition = partition_for(partition_key, partition_count),
         {:ok, offset} <-
           :brod.produce_sync_offset(client_id, config.topic, partition, <<>>, message) do
      KafkaClientManager.touch(outbound_integration.id)
      {:ok, %{kafka_offset: offset, kafka_partition: partition}}
    else
      {:error, reason} ->
        {:error,
         %{
           error_message: "Kafka error: #{inspect(reason)}",
           retryable: retryable_error?(reason)
         }}
    end
  end

  @doc false
  def parse_brokers(brokers) do
    Enum.map(brokers, fn broker ->
      case String.split(broker, ":", parts: 2) do
        [host, port] -> {String.to_charlist(host), String.to_integer(port)}
        [host] -> {String.to_charlist(host), 9092}
      end
    end)
  end

  defp build_client_config(config) do
    case config.security do
      %Ash.Union{type: :none} ->
        []

      %Ash.Union{type: :tls} ->
        [ssl: true]

      %Ash.Union{type: :sasl, value: sasl} ->
        [sasl: sasl_tuple(sasl)]

      %Ash.Union{type: :sasl_tls, value: sasl} ->
        [ssl: true, sasl: sasl_tuple(sasl)]
    end
  end

  defp sasl_tuple(sasl) do
    {:ok, loaded} = Ash.load(sasl, [:password], domain: AshIntegration.domain())
    {loaded.mechanism, loaded.username, loaded.password}
  end

  defp resolve_partition_count(client_id, topic) do
    case :brod.get_partitions_count(client_id, topic) do
      {:ok, count} -> count
      {:error, _} -> 1
    end
  end

  @doc false
  def partition_for(_key, 1), do: 0

  @doc false
  def partition_for(key, count) do
    :erlang.phash2(key, count)
  end

  @doc false
  # Broker availability
  def retryable_error?(:leader_not_available), do: true
  def retryable_error?(:not_leader_for_partition), do: true
  def retryable_error?(:broker_not_available), do: true
  def retryable_error?(:replica_not_available), do: true
  def retryable_error?(:preferred_leader_not_available), do: true
  # Replication
  def retryable_error?(:not_enough_replicas), do: true
  def retryable_error?(:not_enough_replicas_after_append), do: true
  # Timeouts and network
  def retryable_error?(:request_timed_out), do: true
  def retryable_error?(:timeout), do: true
  def retryable_error?(:network_exception), do: true
  def retryable_error?({:connect_error, _}), do: true
  # Coordinator
  def retryable_error?(:coordinator_not_available), do: true
  def retryable_error?(:not_coordinator), do: true
  # Catch-all: unknown errors default to non-retryable to surface permanent
  # failures quickly rather than burning through Oban retry attempts.
  def retryable_error?(_), do: false

  defp acks_to_brod(:all), do: -1
  defp acks_to_brod(:leader), do: 1
  defp acks_to_brod(:none), do: 0
end
