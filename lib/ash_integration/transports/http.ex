defmodule AshIntegration.Transports.Http do
  @moduledoc false

  @behaviour AshIntegration.Transport

  @impl true
  def deliver(outbound_integration, event_id, payload) do
    config = outbound_integration.transport_config
    json_payload = Jason.encode!(payload)

    custom_headers = Enum.map(config.headers || %{}, fn {k, v} -> {k, v} end)

    headers =
      [
        {"content-type", "application/json"},
        {"x-event-id", event_id}
      ] ++ auth_headers(config.auth) ++ custom_headers ++ signature_headers(config, json_payload)

    req_options = Application.get_env(:ash_integration, :req_options, [])

    case Req.request(
           [
             method: config.method || :post,
             url: config.url,
             body: json_payload,
             headers: headers,
             receive_timeout: config.timeout_ms,
             retry: false
           ] ++ req_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, %{response_status: status, response_body: body_to_string(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         %{
           error_message: "HTTP #{status}",
           retryable: status >= 500,
           response_status: status,
           response_body: body_to_string(body)
         }}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, %{error_message: "Network error: #{inspect(reason)}", retryable: true}}

      {:error, reason} ->
        {:error, %{error_message: "Network error: #{inspect(reason)}", retryable: true}}
    end
  end

  defp auth_headers(%Ash.Union{type: :bearer_token, value: auth}) do
    {:ok, auth} = Ash.load(auth, [:token], domain: AshIntegration.domain())
    [{"authorization", "Bearer #{auth.token}"}]
  end

  defp auth_headers(%Ash.Union{type: :api_key, value: auth}) do
    {:ok, auth} = Ash.load(auth, [:value], domain: AshIntegration.domain())
    [{auth.header_name, auth.value}]
  end

  defp auth_headers(%Ash.Union{type: :basic_auth, value: auth}) do
    {:ok, auth} = Ash.load(auth, [:password], domain: AshIntegration.domain())
    encoded = Base.encode64("#{auth.username}:#{auth.password}")
    [{"authorization", "Basic #{encoded}"}]
  end

  defp auth_headers(%Ash.Union{type: :none}), do: []

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

  defp body_to_string(body) when is_binary(body), do: body

  defp body_to_string(body) do
    case Jason.encode(body) do
      {:ok, json} -> json
      {:error, _} -> inspect(body)
    end
  end
end
