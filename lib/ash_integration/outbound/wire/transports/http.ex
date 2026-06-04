defmodule AshIntegration.Outbound.Wire.Transports.Http do
  @moduledoc false
  # Event-first HTTP transport. REPLAYS the snapshot-at-dispatch delivery
  # descriptor on `event.delivery` — method, absolute URL, the resolved wire
  # metadata headers — and ENCODES the stored body term to bytes here. Two
  # secret-derived headers are injected LIVE (never persisted, never in the
  # sandbox): `Authorization`/auth, the decrypted credential, as a FALLBACK (a
  # transform-set authorization wins); and `x-signature`, a send-time MAC computed
  # fresh over the encoded body (so a rotated secret auto-applies and the
  # anti-replay `t` stays honest on retries). Classifies a non-2xx as `:response`
  # and a connection-level error as `:transport`, driving two-level suspension.

  @behaviour AshIntegration.Outbound.Wire.Transport

  alias AshIntegration.Transport.Utils

  @impl true
  def deliver(_connection, %{subscription: %Ash.NotLoaded{}}) do
    # The HTTP transport reads the per-route timeout live from `event.subscription`.
    # A caller that forgot the preload should get a classified, non-retryable error
    # — not an `Ash.NotLoaded` crash that tears down the delivery batcher.
    {:error,
     %{
       failure_class: :transport,
       retryable: false,
       error_message:
         "event.subscription was not loaded before delivery (load [:subscription] " <>
           "on the EventDelivery first)"
     }}
  end

  def deliver(connection, event) do
    %Ash.Union{type: :http, value: config} = connection.transport_config
    delivery = event.delivery
    # Encode the stored body term ONCE here and sign over those exact bytes, so
    # the live x-signature is over precisely what goes on the wire (parity).
    body = Utils.encode_body(delivery["body"])

    # Both secret-derived inputs are loaded LIVE here. A decryption/vault failure
    # short-circuits to a classified `:transport` error (NOT a raised MatchError)
    # so the suspension subsystem sees it instead of retrying forever.
    with {:ok, signature} <- AshIntegration.Transport.Signing.signature(config, body),
         {:ok, auth} <- auth_headers(config.auth) do
      do_deliver(event, config, body, auth, signature)
    end
  end

  defp do_deliver(event, config, body, auth, signature) do
    delivery = event.delivery

    # Re-validate the snapshotted URL against the egress policy right before the
    # send — a backstop against DNS rebinding between dispatch and delivery, and
    # against snapshots materialized before the policy existed. The resolver
    # already parked anything that fails this at dispatch time.
    case AshIntegration.Transport.Egress.validate(delivery["url"]) do
      :ok -> do_send(event, config, body, auth, signature)
      {:error, reason} -> egress_error(reason)
    end
  end

  defp do_send(event, config, body, auth, signature) do
    delivery = event.delivery
    req_options = Application.get_env(:ash_integration, :req_options, [])

    case Req.request(
           [
             method: method(delivery["method"]),
             url: delivery["url"],
             body: body,
             headers: headers(auth, delivery["headers"], signature),
             receive_timeout: timeout(event.subscription.route_config, config),
             retry: false
           ] ++ req_options
         ) do
      {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
        {:ok, %{response_status: status, response_body: Utils.body_to_string(resp)}}

      {:ok, %Req.Response{status: status, body: resp}} ->
        {:error,
         %{
           failure_class: :response,
           error_message: "HTTP #{status}",
           retryable: status >= 500,
           response_status: status,
           response_body: Utils.body_to_string(resp)
         }}

      {:error, %Req.TransportError{reason: reason}} ->
        transport_error(reason)

      {:error, reason} ->
        transport_error(reason)
    end
  end

  defp transport_error(reason) do
    {:error,
     %{
       failure_class: :transport,
       error_message: "Network error: #{Utils.scrub_reason(reason)}",
       retryable: true
     }}
  end

  # A blocked egress target won't fix itself on retry — surface it as a
  # non-retryable transport failure rather than looping.
  defp egress_error(reason) do
    {:error, %{failure_class: :transport, error_message: reason, retryable: false}}
  end

  # Both secret-derived headers are injected LIVE here (never in the event row or
  # the sandbox). Precedence (lowest→highest, de-dup keeps last):
  #   auth (fallback)  →  stored resolved headers  →  signature
  # so a transform-set `authorization` overrides the connection auth, while
  # `x-signature` is library-owned and wins over any transform-set value.
  defp headers(auth, stored, signature) do
    stored = Enum.map(stored || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    (auth ++ stored ++ signature_header(signature))
    |> Utils.dedup_keep_last()
  end

  defp signature_header(nil), do: []
  defp signature_header(signature), do: [{"x-signature", signature}]

  # Per-route timeout override stays LIVE (it's a client setting, not wire data).
  defp timeout(%Ash.Union{type: :http, value: route}, config),
    do: route.timeout_ms || config.timeout_ms

  defp timeout(_route, config), do: config.timeout_ms

  defp method("put"), do: :put
  defp method("patch"), do: :patch
  defp method("delete"), do: :delete
  defp method(_post), do: :post

  defp auth_headers(%Ash.Union{type: :bearer_token, value: auth}) do
    with {:ok, auth} <- Utils.load_secret(auth, [:token], "bearer token") do
      {:ok, [{"authorization", "Bearer #{auth.token}"}]}
    end
  end

  defp auth_headers(%Ash.Union{type: :api_key, value: auth}) do
    with {:ok, auth} <- Utils.load_secret(auth, [:value], "API key") do
      {:ok, [{auth.header_name, auth.value}]}
    end
  end

  defp auth_headers(%Ash.Union{type: :basic_auth, value: auth}) do
    with {:ok, auth} <- Utils.load_secret(auth, [:password], "basic auth credentials") do
      {:ok, [{"authorization", "Basic #{Base.encode64("#{auth.username}:#{auth.password}")}"}]}
    end
  end

  defp auth_headers(%Ash.Union{type: :none}), do: {:ok, []}
end
