defmodule AshIntegration.Transports.Grpc do
  @moduledoc false

  @behaviour AshIntegration.Transport

  alias AshIntegration.Transports.Grpc.{ProtoRegistry, Channel, Codec}

  @impl true
  def deliver(outbound_integration, event_id, _resource_id, payload) do
    %Ash.Union{type: :grpc, value: config} = outbound_integration.transport_config
    json_payload = Jason.encode!(payload)
    integration_id = to_string(outbound_integration.id)

    with {:ok, descriptor} <- ProtoRegistry.get_or_parse(integration_id, config.proto_definition),
         {:ok, input_type} <-
           ProtoRegistry.resolve_input_type(descriptor, config.service, config.method),
         {:ok, encoded} <- Codec.encode(payload, input_type),
         {:ok, channel} <- Channel.get_or_connect(integration_id, config) do
      path = "/#{config.service}/#{config.method}"

      custom_headers =
        Enum.map(config.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

      metadata =
        [{"x-event-id", event_id}, {"x-integration-id", integration_id}] ++
          custom_headers ++
          auth_metadata(config) ++
          signature_metadata(config, json_payload)

      case Channel.unary_call(channel, integration_id, path, encoded, metadata, config.timeout_ms) do
        {:ok, %{status: 0, body: body}} ->
          {:ok, %{response_status: 200, response_body: inspect(body, limit: 200)}}

        {:ok, %{status: grpc_status, message: message}} ->
          http_equiv = grpc_status_to_http(grpc_status)

          {:error,
           %{
             error_message: "gRPC status #{grpc_status}: #{message}",
             retryable: http_equiv >= 500,
             response_status: http_equiv,
             response_body: message
           }}

        {:error, reason} ->
          {:error, %{error_message: "gRPC error: #{inspect(reason)}", retryable: true}}
      end
    else
      {:error, reason} ->
        {:error, %{error_message: "gRPC setup error: #{inspect(reason)}", retryable: false}}
    end
  end

  defp auth_metadata(%{security: %Ash.Union{type: :bearer_token, value: sec}}) do
    {:ok, loaded} = Ash.load(sec, [:token], domain: AshIntegration.domain())
    [{"authorization", "Bearer #{loaded.token}"}]
  end

  defp auth_metadata(_), do: []

  defp signature_metadata(%{signing_secret: nil}, _body), do: []

  defp signature_metadata(config, body) do
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

  defp grpc_status_to_http(0), do: 200
  defp grpc_status_to_http(4), do: 504
  defp grpc_status_to_http(8), do: 429
  defp grpc_status_to_http(14), do: 503
  defp grpc_status_to_http(3), do: 400
  defp grpc_status_to_http(5), do: 404
  defp grpc_status_to_http(7), do: 403
  defp grpc_status_to_http(12), do: 501
  defp grpc_status_to_http(16), do: 401
  defp grpc_status_to_http(_), do: 500
end
