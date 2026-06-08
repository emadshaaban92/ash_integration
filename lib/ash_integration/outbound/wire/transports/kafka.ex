defmodule AshIntegration.Outbound.Wire.Transports.Kafka do
  @moduledoc false
  # Event-first Kafka transport. REPLAYS the snapshot-at-dispatch delivery
  # descriptor on `event.delivery` — topic, partition key, the native record
  # timestamp (`ts`, epoch ms; defaulted from the event's created_at at dispatch
  # instead of letting brod stamp produce-time), bare hyphenated wire-metadata
  # headers — and ENCODES the stored value term to bytes. The bare `signature`
  # header is computed LIVE over those bytes (a send-time MAC, never stored), so a
  # rotated secret auto-applies. Kafka has no per-message auth header (security is
  # connection-level TLS/SASL). Failures are essentially all transport-level (the
  # broker accepts bytes without semantic validation), so they classify as
  # `:transport`.

  @behaviour AshIntegration.Outbound.Wire.Transport

  alias AshIntegration.Transport.KafkaClientManager
  alias AshIntegration.Transport.Signing
  alias AshIntegration.Transport.Utils

  @impl true
  def deliver(connection, event) do
    if Utils.available?(:kafka) do
      do_deliver(connection, event)
    else
      {:error,
       %{
         failure_class: :transport,
         error_message:
           "Kafka transport is not available. Add {:brod, \"~> 4.0\"} to your dependencies.",
         retryable: false
       }}
    end
  end

  @doc false
  # The brod message for `event` (no broker contact), built from the stored
  # delivery descriptor. Exposed for testing the replay mapping: the partition key
  # is the descriptor's `key`, headers are bare, and `ts` carries the native record
  # timestamp. The value is encoded here and the bare `signature` is computed LIVE
  # over those exact bytes (send-time MAC, never stored) — an empty value encodes
  # to `<<>>` (NOT nil; brod's `bin/1` only maps `undefined`, a nil would crash
  # `iolist_to_binary/1`).
  #
  # Returns `{:ok, message}`, or `{:error, classified}` when decrypting the signing
  # secret fails — surfaced as a `:transport` failure rather than a raised
  # MatchError so the suspension subsystem sees it.
  def build_message(connection, event) do
    %Ash.Union{type: :kafka, value: config} = connection.transport_config
    delivery = event.delivery
    value = Utils.encode_body(delivery["value"]) || ""
    ctx = build_ctx(delivery, value)

    with {:ok, applied} <- Signing.run(config.signing, ctx) do
      final_value = if applied.body == :keep, do: value, else: applied.body

      {:ok,
       %{
         key: delivery["key"],
         value: final_value,
         ts: delivery["timestamp"],
         headers: headers(delivery["headers"], applied.headers)
       }}
    end
  end

  # The send-time signing context. `body` is the record value bytes (what a default
  # signer hashes); `data` is the structured value; `now` is frozen per attempt.
  # There is no method/path/url — a `url` placement callback simply doesn't apply.
  defp build_ctx(delivery, value) do
    %{
      topic: delivery["topic"],
      key: to_string(delivery["key"]),
      headers: Map.new(delivery["headers"] || %{}, fn {k, v} -> {to_string(k), to_string(v)} end),
      body: value,
      data: delivery["value"],
      now: Signing.now_context()
    }
  end

  # Bare wire headers replayed from the descriptor, with the library-owned signing
  # headers appended last so they win the de-dup.
  defp headers(stored, sig_headers) do
    stored = Enum.map(stored || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
    Utils.dedup_keep_last(stored ++ sig_headers)
  end

  defp do_deliver(connection, event) do
    %Ash.Union{type: :kafka, value: config} = connection.transport_config
    topic = event.delivery["topic"]

    if is_nil(topic) do
      {:error,
       %{
         failure_class: :transport,
         error_message: "No Kafka topic configured on the subscription or connection",
         retryable: false
       }}
    else
      produce(connection, event, config, topic)
    end
  end

  defp produce(connection, event, config, topic) do
    brokers = Utils.parse_brokers(config.brokers)
    client_id = KafkaClientManager.client_id_for(connection.id)

    producer_config = [
      required_acks: acks_to_brod(config.acks),
      max_linger_ms: 0,
      max_linger_count: 0
    ]

    with {:ok, message} <- build_message(connection, event),
         {:ok, client_config} <- build_client_config(config),
         :ok <-
           KafkaClientManager.ensure_client(
             connection.id,
             brokers,
             client_config,
             topic,
             producer_config
           ),
         {:ok, partition_count} <- resolve_partition_count(client_id, topic),
         partition = Utils.partition_for(message.key, partition_count),
         {:ok, offset} <-
           :brod.produce_sync_offset(client_id, topic, partition, <<>>, message) do
      KafkaClientManager.touch(connection.id)
      {:ok, %{kafka_offset: offset, kafka_partition: partition}}
    else
      # A secret-load failure from build_message/build_client_config is already
      # classified — pass it through rather than re-wrapping it as a generic broker
      # error (which would lose its message and retryable verdict).
      {:error, %{failure_class: _} = classified} ->
        {:error, classified}

      {:error, reason} ->
        {:error,
         %{
           failure_class: :transport,
           error_message: "Kafka error: #{Utils.scrub_reason(reason)}",
           retryable: Utils.retryable_error?(reason)
         }}
    end
  end

  defp build_client_config(config) do
    case config.security do
      %Ash.Union{type: :none} ->
        {:ok, []}

      %Ash.Union{type: :tls} ->
        {:ok, [ssl: true]}

      %Ash.Union{type: :sasl, value: sasl} ->
        with {:ok, tuple} <- sasl_tuple(sasl), do: {:ok, [sasl: tuple]}

      %Ash.Union{type: :sasl_tls, value: sasl} ->
        with {:ok, tuple} <- sasl_tuple(sasl), do: {:ok, [ssl: true, sasl: tuple]}
    end
  end

  defp sasl_tuple(sasl) do
    with {:ok, loaded} <- Utils.load_secret(sasl, [:password], "Kafka SASL credentials") do
      {:ok, {loaded.mechanism, loaded.username, loaded.password}}
    end
  end

  # The partition count drives murmur2 key→partition selection. If brod can't read
  # it (metadata not yet refreshed, broker transiently unavailable), DO NOT default
  # to partition 0 — that silently routes every key to one partition and breaks
  # per-key ordering on a multi-partition topic. Surface a retryable transport
  # error so the delivery is retried (and the connection counter tracks it) once
  # metadata is available.
  defp resolve_partition_count(client_id, topic) do
    case :brod.get_partitions_count(client_id, topic) do
      {:ok, count} ->
        {:ok, count}

      {:error, reason} ->
        {:error,
         %{
           failure_class: :transport,
           error_message:
             "Could not resolve partition count for topic #{inspect(topic)}: " <>
               "#{Utils.scrub_reason(reason)}",
           retryable: true
         }}
    end
  end

  defp acks_to_brod(:all), do: -1
  defp acks_to_brod(:leader), do: 1
  defp acks_to_brod(:none), do: 0
end
