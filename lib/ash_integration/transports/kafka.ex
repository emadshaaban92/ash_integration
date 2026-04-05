defmodule AshIntegration.Transports.Kafka do
  @moduledoc false

  @behaviour AshIntegration.Transport

  require Logger

  alias AshIntegration.KafkaClientManager

  @impl true
  def deliver(outbound_integration, event_id, resource_id, payload) do
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
        signature_headers(config, json_payload)

    message = %{
      key: partition_key,
      value: json_payload,
      headers: headers
    }

    with :ok <-
           KafkaClientManager.ensure_client(
             outbound_integration.id,
             brokers,
             client_config,
             config.topic
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

  defp parse_brokers(brokers) do
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

  defp partition_for(_key, 1), do: 0

  defp partition_for(key, count) do
    :erlang.phash2(key, count)
  end

  defp signature_headers(%{signing_secret: nil}, _body), do: []

  defp signature_headers(config, body) do
    {:ok, config} = Ash.load(config, [:signing_secret], domain: AshIntegration.domain())

    case config.signing_secret do
      secret when is_binary(secret) and secret != "" ->
        timestamp = System.system_time(:second)
        signed_payload = "#{timestamp}.#{body}"

        signature =
          :crypto.mac(:hmac, :sha256, secret, signed_payload)
          |> Base.encode16(case: :lower)

        [{"x-webhook-signature", "t=#{timestamp},v1=#{signature}"}]

      _ ->
        []
    end
  end

  defp retryable_error?(:leader_not_available), do: true
  defp retryable_error?(:not_leader_for_partition), do: true
  defp retryable_error?(:request_timed_out), do: true
  defp retryable_error?(:not_enough_replicas), do: true
  defp retryable_error?({:connect_error, _}), do: true
  defp retryable_error?(:timeout), do: true
  defp retryable_error?(_), do: false
end
