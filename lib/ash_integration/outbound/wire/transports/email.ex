defmodule AshIntegration.Outbound.Wire.Transports.Email do
  @moduledoc false
  # Event-first email transport. REPLAYS the snapshot-at-dispatch delivery
  # descriptor on `event.delivery` — from, recipients, subject, html/text body,
  # and the `x-`-prefixed wire-metadata headers — and rebuilds a `Swoosh.Email`
  # from it. The single live secret carve-out is the SMTP credential (decrypted per
  # send, never persisted), injected into the Swoosh adapter config rather than the
  # message. Delivery goes through Swoosh's SMTP adapter (gen_smtp under the hood),
  # which opens a connection per send — so the transport stays stateless in the
  # relay, exactly like HTTP. `gen_smtp` already distinguishes permanent from
  # temporary failures, which map cleanly onto the two-level suspension model: a
  # permanent SMTP rejection is `:response`/non-retryable (the payload/recipient is
  # wrong → suspend the subscription), a temporary one is `:response`/retryable, and
  # anything connection-level is `:transport`.
  #
  # Building on Swoosh makes SMTP-vs-provider-API a *config* choice, not a code
  # fork: a native provider-API adapter (SES, SendGrid, …) can be added later as a
  # new `EmailConfig.adapter` union variant behind the same `:email` tag.

  @behaviour AshIntegration.Outbound.Wire.Transport

  require Logger

  alias AshIntegration.Transport.Egress
  alias AshIntegration.Transport.TlsOptions
  alias AshIntegration.Transport.Utils

  @impl true
  def deliver(connection, event) do
    if Utils.available?(:email) do
      do_deliver(connection, event)
    else
      {:error,
       %{
         failure_class: :transport,
         error_message:
           "Email transport is not available. Add {:swoosh, \"~> 1.0\"} and " <>
             "{:gen_smtp, \"~> 1.0\"} to your dependencies.",
         retryable: false
       }}
    end
  end

  defp do_deliver(connection, event) do
    %Ash.Union{type: :email, value: config} = connection.transport_config

    with {:ok, email} <- build_email(connection, event),
         {:ok, adapter, adapter_config} <- adapter_config(config.adapter, email) do
      send_email(adapter, email, adapter_config)
    end
  end

  @doc false
  # The `Swoosh.Email` for `event` (no network), built from the stored delivery
  # descriptor. Exposed for testing the replay mapping without an SMTP server. The
  # descriptor was already normalized/validated by the resolver (recipients present,
  # subject present, a body present, no header-injection control chars), so this is
  # a pure projection onto the Swoosh struct.
  def build_email(connection, event) do
    %Ash.Union{type: :email, value: config} = connection.transport_config
    delivery = event.delivery
    from = delivery["from"] || config.from

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from(parse_from(from))
      |> put_recipients(delivery["to"], &Swoosh.Email.to/2)
      |> put_recipients(delivery["cc"], &Swoosh.Email.cc/2)
      |> put_recipients(delivery["bcc"], &Swoosh.Email.bcc/2)
      |> Swoosh.Email.subject(delivery["subject"] || "")
      |> put_body(delivery["html"], &Swoosh.Email.html_body/2)
      |> put_body(delivery["text"], &Swoosh.Email.text_body/2)
      |> put_headers(delivery["headers"])
      |> put_client_options(Map.get(config, :adapter))

    {:ok, email}
  end

  # Defense-in-depth for the Graph SEND path. Swoosh's Req ApiClient reads Req
  # options from `email.private[:client_options]`, so pass `redirect: false`
  # there — mirroring the token request and the HTTP transport — so the send never
  # chases a 3xx. The host is the fixed public graph.microsoft.com, so this is
  # belt-and-braces rather than an active SSRF fix. The same seam lets test config
  # (`:graph_req_options`) route the send through `Req.Test` to assert the final
  # request path. The SMTP adapter ignores `client_options`, so this is a no-op for
  # it, but only the Graph adapter needs it.
  defp put_client_options(email, %Ash.Union{type: :ms_graph}) do
    opts = [redirect: false] ++ Application.get_env(:ash_integration, :graph_req_options, [])
    Swoosh.Email.put_private(email, :client_options, opts)
  end

  defp put_client_options(email, _adapter), do: email

  # Swoosh takes a sender as `{name, address}` or a bare `address`. Split the
  # common `"Display Name <addr@host>"` form so the From header is well-formed;
  # a bare address passes through unchanged.
  defp parse_from(from) do
    case Regex.run(~r/\A\s*(.*?)\s*<([^>]+)>\s*\z/, to_string(from)) do
      [_, name, address] -> {name, address}
      _ -> from
    end
  end

  defp put_recipients(email, nil, _fun), do: email
  defp put_recipients(email, [], _fun), do: email
  defp put_recipients(email, recipients, fun), do: fun.(email, recipients)

  defp put_body(email, nil, _fun), do: email
  defp put_body(email, "", _fun), do: email
  defp put_body(email, body, fun), do: fun.(email, body)

  defp put_headers(email, headers) when is_map(headers) do
    Enum.reduce(headers, email, fn {name, value}, acc ->
      Swoosh.Email.header(acc, to_string(name), to_string(value))
    end)
  end

  defp put_headers(email, _headers), do: email

  @doc false
  # Resolve the Swoosh adapter + config for the connection's adapter union, folding
  # in the live secret carve-out (SMTP password / OAuth2 access token). Exposed for
  # testing the adapter wiring — including the SMTP TLS-options shape and the
  # STARTTLS-downgrade warning — without a live SMTP/Graph endpoint.
  #
  # The SMTP credential is the live carve-out: decrypted per send via `load_secret`
  # (a rotated password auto-applies, a decrypt failure classifies as a
  # non-retryable `:transport` error instead of crashing the batcher) and folded
  # into the gen_smtp config, never into the stored descriptor.
  #
  # `tls_options` is verified-by-default (see `TlsOptions`): certs are checked on
  # both the implicit-SSL (`ssl: true`) and STARTTLS-upgrade paths unless the
  # operator sets `verify: :verify_none` on this one connection.
  def adapter_config(%Ash.Union{type: :smtp, value: smtp}, _email) do
    with {:ok, loaded} <- Utils.load_secret(smtp, [:password], "SMTP password"),
         {:ok, tls_options} <- tls_options(smtp) do
      warn_starttls_downgrade(smtp)

      config =
        [
          relay: smtp.relay,
          port: smtp.port,
          username: smtp.username,
          password: loaded.password,
          ssl: smtp.ssl,
          tls: smtp.tls,
          auth: smtp.auth,
          tls_options: tls_options,
          retries: 1
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, Swoosh.Adapters.SMTP, config}
    end
  end

  # Microsoft Graph app-only send. The client-credentials access token is the live
  # carve-out: decrypt the client secret, fetch (or reuse a cached) token from the
  # shared provider, and hand it to Swoosh's MsGraph adapter via its `auth` fn seam.
  # A token-fetch failure is already classified onto the transport contract, so it
  # short-circuits here before any send is attempted. An optional `user_id` pins the
  # sending mailbox via the adapter's `:url` override.
  def adapter_config(%Ash.Union{type: :ms_graph, value: ms_graph}, email) do
    with {:ok, loaded} <-
           Utils.load_secret(ms_graph.oauth2, [:client_secret], "OAuth2 client secret"),
         {:ok, token} <- AshIntegration.Transport.OAuth2.get_token(loaded) do
      config = [auth: fn -> token end, url: ms_graph_url(ms_graph.user_id, email)]
      {:ok, Swoosh.Adapters.MsGraph, config}
    end
  end

  # ALWAYS pin an explicit `:url`, so Swoosh's MsGraph adapter never builds the
  # endpoint itself. Left to its own devices it interpolates the message `from`
  # (which a Lua transform can set to a path-bearing string) into the URL with NO
  # encoding — request-forgery across the `.default`-scoped Graph surface. Here the
  # sending mailbox — an explicit `user_id` override, else the resolved `from`
  # address — is percent-encoded with a reserved-safe predicate so no path/query
  # metacharacter (`/ ? # @ ...`) survives to rewrite the path or query.
  defp ms_graph_url(user_id, _email) when is_binary(user_id) and user_id != "" do
    build_send_url(user_id)
  end

  defp ms_graph_url(_user_id, email), do: build_send_url(mailbox_address(email))

  defp build_send_url(mailbox) do
    "https://graph.microsoft.com/v1.0/users/" <>
      URI.encode(mailbox, &URI.char_unreserved?/1) <> "/sendMail"
  end

  # Swoosh normalizes a sender to a `{name, address}` tuple; the mailbox is the
  # address part. Falls back to "" for a malformed sender (rejected upstream by the
  # `from` format validation, so this only guards against a truly empty address).
  defp mailbox_address(%Swoosh.Email{from: {_name, address}}) when is_binary(address), do: address
  defp mailbox_address(_email), do: ""

  # A bad `cacert_pem` is an operator misconfiguration on this connection —
  # classify it as a non-retryable transport failure rather than crashing the
  # batcher (mirrors `load_secret`'s treatment of a decrypt failure).
  defp tls_options(smtp) do
    case TlsOptions.build(smtp) do
      {:ok, opts} ->
        {:ok, opts}

      {:error, message} ->
        {:error,
         %{
           failure_class: :transport,
           error_message: "SMTP TLS configuration error: #{message}",
           retryable: false
         }}
    end
  end

  # `tls: :if_available` lets an active attacker STRIP the STARTTLS offer and
  # keep the session in plaintext — acceptable for the internal plaintext relays
  # this library must keep supporting, but a real downgrade risk for an
  # internet-facing relay. We DON'T force `:always` (that would break those
  # internal relays); instead we warn once per relay when `:if_available` is used
  # against a non-internal host, recommending `:always` there. Host classification
  # reuses `Egress` rather than reimplementing CIDR/loopback checks.
  defp warn_starttls_downgrade(%{tls: :if_available, relay: relay})
       when is_binary(relay) do
    key = {__MODULE__, :starttls_downgrade_warned, relay}

    if not :persistent_term.get(key, false) and not Egress.internal_host?(relay) do
      :persistent_term.put(key, true)

      Logger.warning(
        "SMTP relay #{relay} is configured with tls: :if_available, which lets an " <>
          "active attacker strip STARTTLS and deliver over plaintext. For an " <>
          "internet-facing relay, set tls: :always on this connection."
      )
    end

    :ok
  end

  defp warn_starttls_downgrade(_smtp), do: :ok

  defp send_email(adapter, email, adapter_config) do
    case adapter.deliver(email, adapter_config) do
      {:ok, receipt} ->
        {:ok, %{email_response: Utils.body_to_string(receipt)}}

      {:error, reason} ->
        {:error, classify_error(reason)}
    end
  end

  @doc false
  # Map a Swoosh/gen_smtp failure onto the two-level suspension contract. gen_smtp
  # nests its reason inside `:retries_exceeded`/`:network_failure`, so unwrap first.
  #
  #   * `:permanent_failure` (5xx SMTP — bad recipient, rejected content) →
  #     `:response`, non-retryable: the target rejected THIS payload, suspend the
  #     subscription.
  #   * `:temporary_failure` (4xx SMTP — greylisting, rate limit) → `:response`,
  #     retryable: fine to try again later.
  #   * everything connectivity-shaped (refused, timeout, DNS, no hosts) →
  #     `:transport`, retryable: couldn't reach the relay, suspend the connection.
  #   * unknown reasons default to `:transport`/retryable, mirroring the HTTP
  #     transport's treatment of an unrecognized network error.
  def classify_error({:retries_exceeded, inner}), do: classify_error(inner)
  def classify_error({:network_failure, _host, inner}), do: classify_error(inner)
  def classify_error({:error, reason}), do: classify_error(reason)

  def classify_error({:permanent_failure, _host, message}),
    do: response_error(message, false)

  def classify_error({:temporary_failure, _host, message}),
    do: response_error(message, true)

  def classify_error({:no_more_hosts, _reason} = reason),
    do: transport_error(reason, true)

  def classify_error(reason) when reason in [:no_credentials, :auth_failed],
    do: transport_error(reason, false)

  def classify_error(reason), do: transport_error(reason, true)

  defp response_error(message, retryable) do
    %{
      failure_class: :response,
      error_message: "SMTP rejected: #{Utils.scrub_reason(message)}",
      retryable: retryable
    }
  end

  defp transport_error(reason, retryable) do
    %{
      failure_class: :transport,
      error_message: "SMTP error: #{Utils.scrub_reason(reason)}",
      retryable: retryable
    }
  end
end
