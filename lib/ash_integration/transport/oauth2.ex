defmodule AshIntegration.Transport.OAuth2 do
  @moduledoc """
  Reusable OAuth2 **client-credentials** token provider, shared by the HTTP and
  Email transports.

  Only the two-legged, machine-to-machine (app-only) client-credentials grant is
  supported — no authorization-code/consent flow, no refresh tokens, no per-user
  delegation. `get_token/1` returns a cached access token for a decrypted
  `AshIntegration.Transport.OAuth2.ClientCredentials` descriptor, fetching a fresh
  one only when the cache is cold or the cached token is near expiry. Concurrent
  deliveries for the same credential coalesce to a single in-flight fetch
  (single-flight) via `AshIntegration.Transport.OAuth2.TokenCache`.

  Failures are classified onto the transport contract
  (`%{failure_class: :transport, error_message: String.t(), retryable: boolean()}`):
  a network error or a transient 5xx/429 from the token endpoint is retryable; a
  `400/401` (bad/rotated credentials) is non-retryable — it will not fix itself on
  retry, so the two-level suspension subsystem should see it. The `client_secret`
  and the access token are never logged (everything routed through
  `Utils.scrub_reason/1`) and never persisted.
  """

  alias AshIntegration.Transport.Egress
  alias AshIntegration.Transport.OAuth2.TokenCache
  alias AshIntegration.Transport.Utils

  @typedoc "A decrypted client-credentials descriptor (the `client_secret` loaded)."
  @type descriptor :: struct()

  @doc """
  Get a valid access token for `descriptor`, reusing a cached one when possible.

  `descriptor` must already have its `client_secret` decrypted (via
  `Utils.load_secret/3`). Returns `{:ok, token}` or a classified
  `{:error, transport_error}`.
  """
  @spec get_token(descriptor()) :: {:ok, String.t()} | {:error, map()}
  def get_token(descriptor) do
    TokenCache.get_token(cache_key(descriptor), descriptor)
  end

  @doc """
  A stable cache key for `descriptor`. Hashes the token endpoint, client id,
  scopes/audience/extra params, the auth style, AND the decrypted secret — so a
  rotated `client_secret` yields a new key and invalidates the cached token,
  while the plaintext secret never appears in the key itself.
  """
  @spec cache_key(descriptor()) :: binary()
  def cache_key(descriptor) do
    material = [
      descriptor.token_url,
      descriptor.client_id,
      descriptor.scopes,
      descriptor.audience,
      inspect(descriptor.extra_params || %{}),
      to_string(descriptor.auth_style),
      descriptor.client_secret
    ]

    :crypto.hash(:sha256, Enum.map_join(material, "\n", &to_string/1))
  end

  @doc false
  # The actual token fetch: POST the client-credentials grant to the token
  # endpoint, pinned through the SSRF egress gate, and parse/classify the result.
  # Runs in the caller (leader) process so it stays visible to per-process test
  # stubs. Returns `{:ok, %{token: token, expires_in: seconds}}` or a classified
  # `{:error, transport_error}`.
  @spec request_token(descriptor()) :: {:ok, map()} | {:error, map()}
  def request_token(descriptor) do
    case Egress.pin(descriptor.token_url) do
      {:ok, url, connect_options} ->
        do_request(descriptor, url, connect_options)

      {:error, :unresolvable, message} ->
        {:error, transport_error(message, true)}

      {:error, _category, message} ->
        {:error, transport_error(message, false)}
    end
  end

  defp do_request(descriptor, url, connect_options) do
    {form, headers} = build_request(descriptor)
    req_options = Application.get_env(:ash_integration, :oauth2_req_options, [])

    options =
      [
        method: :post,
        url: url,
        form: form,
        headers: headers,
        retry: false,
        redirect: false
      ] ++ merge_connect_options(req_options, connect_options)

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_token(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        http_error(status, body)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, transport_error("Network error: #{Utils.scrub_reason(reason)}", true)}

      {:error, reason} ->
        {:error, transport_error("Network error: #{Utils.scrub_reason(reason)}", true)}
    end
  end

  # Build the `grant_type=client_credentials` request body + headers per the
  # configured token-endpoint auth style. `:post` puts the credentials in the
  # form; `:basic` moves them into an HTTP Basic `Authorization` header.
  defp build_request(descriptor) do
    base =
      [grant_type: "client_credentials"]
      |> maybe_put(:scope, descriptor.scopes)
      |> maybe_put(:audience, descriptor.audience)
      |> Enum.concat(extra_params(descriptor.extra_params))

    case descriptor.auth_style do
      :basic ->
        credentials = Base.encode64("#{descriptor.client_id}:#{descriptor.client_secret}")
        {base, [{"authorization", "Basic #{credentials}"}]}

      _post ->
        form =
          base
          |> Keyword.put(:client_id, descriptor.client_id)
          |> Keyword.put(:client_secret, descriptor.client_secret)

        {form, []}
    end
  end

  defp extra_params(params) when is_map(params),
    do: Enum.map(params, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp extra_params(_params), do: []

  defp maybe_put(list, _key, value) when value in [nil, ""], do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  # Extract `access_token` + `expires_in` from a parsed (or raw) token response.
  # A body missing the access token — even on a 200 — is a non-retryable protocol
  # error, not something a retry fixes.
  defp parse_token(body) do
    case decode(body) do
      %{"access_token" => token} = decoded when is_binary(token) and token != "" ->
        {:ok, %{token: token, expires_in: expires_in(decoded)}}

      _other ->
        {:error, transport_error("OAuth2 token response missing access_token", false)}
    end
  end

  defp decode(body) when is_map(body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode(_body), do: %{}

  # `expires_in` is seconds. Default conservatively to 60s when absent so an
  # endpoint that omits it still gets cached briefly rather than re-fetched every
  # send.
  defp expires_in(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0,
    do: seconds

  defp expires_in(%{"expires_in" => seconds}) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {value, _} when value > 0 -> value
      _ -> 60
    end
  end

  defp expires_in(_decoded), do: 60

  # A 400/401 from the token endpoint means bad/rotated/misconfigured credentials
  # — a retry sends the same rejected grant, so it is non-retryable (drives
  # suspension). A 5xx or 429 is a transient endpoint condition, worth retrying.
  defp http_error(status, body) do
    detail = token_error_detail(body)
    message = "OAuth2 token endpoint returned HTTP #{status}#{detail}"
    {:error, transport_error(message, status >= 500 or status == 429)}
  end

  # Surface the standard OAuth2 `error` code (never the description, which can
  # echo request material) when present.
  defp token_error_detail(body) do
    case decode(body) do
      %{"error" => error} when is_binary(error) -> " (#{Utils.scrub_reason(error)})"
      _ -> ""
    end
  end

  defp merge_connect_options(req_options, []), do: req_options

  defp merge_connect_options(req_options, connect_options) do
    {existing, rest} = Keyword.pop(req_options, :connect_options, [])
    [{:connect_options, Keyword.merge(existing, connect_options)} | rest]
  end

  defp transport_error(message, retryable) do
    %{failure_class: :transport, error_message: message, retryable: retryable}
  end
end
