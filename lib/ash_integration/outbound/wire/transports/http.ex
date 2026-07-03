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

  alias AshIntegration.Transport.Signing
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
    # the live signature is over precisely what goes on the wire (parity). A
    # `custom` scheme that places the signature IN the body returns replacement
    # bytes; otherwise the cached bytes are sent verbatim.
    body = Utils.encode_body(delivery["body"])
    ctx = build_ctx(delivery, body)

    # Both secret-derived inputs are loaded LIVE here. A decryption/vault failure
    # (or a `custom` script error) short-circuits to a classified `:transport`
    # error so the suspension subsystem sees it instead of retrying forever.
    with {:ok, applied} <- Signing.run(config.signing, ctx),
         {:ok, auth} <- auth_headers(config.auth) do
      do_deliver(event, config, body, applied, auth)
    end
  end

  # The send-time signing context. `body` is the exact wire bytes; `data` is the
  # structured body (for Model-2 canonical strings); `now` is frozen for this
  # attempt and shared across every signing callback.
  defp build_ctx(delivery, body) do
    uri = URI.parse(delivery["url"] || "")

    %{
      method: String.upcase(to_string(delivery["method"] || "post")),
      url: delivery["url"],
      path: path_with_query(uri),
      host: uri.host,
      headers: stringify_headers(delivery["headers"]),
      body: body || "",
      data: delivery["body"],
      now: Signing.now_context()
    }
  end

  defp path_with_query(%URI{path: path, query: nil}), do: path || "/"
  defp path_with_query(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp stringify_headers(headers),
    do: Map.new(headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp do_deliver(event, config, body, applied, auth) do
    delivery = event.delivery
    final_body = if applied.body == :keep, do: body, else: applied.body
    url = if applied.url == :keep, do: delivery["url"], else: applied.url

    # Pin the (possibly signing-rewritten) URL to a validated IP right before the
    # send — the live SSRF gate against DNS rebinding (the checked address is the
    # connected address). An unresolvable URL fails here as a `:transport` error.
    case AshIntegration.Transport.Egress.pin(url) do
      {:ok, url, connect_options} ->
        do_send(event, config, final_body, applied.headers, auth, url, connect_options)

      {:error, _category, reason} ->
        egress_error(reason)
    end
  end

  defp do_send(event, config, body, sig_headers, auth, url, connect_options) do
    delivery = event.delivery
    req_options = Application.get_env(:ash_integration, :req_options, [])

    case Req.request(
           [
             method: method(delivery["method"]),
             url: url,
             body: body,
             headers: headers(auth, delivery["headers"], sig_headers),
             receive_timeout: timeout(event.subscription.route_config, config),
             retry: false,
             # Never follow redirects: a 3xx to an internal address would re-resolve
             # and bypass the pin. A redirect from a webhook target is a misconfig.
             redirect: false
           ] ++ merge_connect_options(req_options, connect_options)
         ) do
      {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
        {:ok, %{response_status: status, response_body: Utils.body_to_string(resp)}}

      {:ok, %Req.Response{status: status, body: resp}} ->
        {:error,
         %{
           failure_class: :response,
           error_message: "HTTP #{status}",
           retryable: retryable_status?(status),
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

  # Which non-2xx statuses are worth retrying. A 5xx is a server-side hiccup; 408
  # (Request Timeout) and 429 (Too Many Requests) are the only two 4xx codes that
  # explicitly mean "the request was fine, try again later" — a transient, load- or
  # timing-driven rejection, not a verdict on this payload. Every OTHER 4xx
  # (400/401/403/404/409/422 …) and every 3xx is deterministic: the target will
  # reject this exact payload no matter how healthy it is, so it is non-retryable.
  # This flag is what the delivery relay's permanent-failure discriminator keys on
  # (`retryable: false` + `:response` ⇒ terminal at once), so misclassifying a
  # transient 429/408 as non-retryable would wrongly take a recoverable delivery
  # terminal on the first hit.
  defp retryable_status?(status), do: status >= 500 or status in [408, 429]

  # A blocked egress target won't fix itself on retry — surface it as a
  # non-retryable transport failure rather than looping.
  defp egress_error(reason) do
    {:error, %{failure_class: :transport, error_message: reason, retryable: false}}
  end

  # Fold the pin's `connect_options` into any operator-set `req_options`, pin wins.
  defp merge_connect_options(req_options, []), do: req_options

  defp merge_connect_options(req_options, connect_options) do
    {existing, rest} = Keyword.pop(req_options, :connect_options, [])
    [{:connect_options, Keyword.merge(existing, connect_options)} | rest]
  end

  # Both secret-derived header groups are injected LIVE here (never in the event
  # row or the sandbox). Precedence (lowest→highest, de-dup keeps last):
  #   auth (fallback)  →  stored resolved headers  →  signing headers
  # so a transform-set `authorization` overrides the connection auth, while the
  # signing headers are library-owned and win over any transform-set value.
  defp headers(auth, stored, sig_headers) do
    stored = Enum.map(stored || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    (auth ++ stored ++ sig_headers)
    |> Utils.dedup_keep_last()
  end

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
