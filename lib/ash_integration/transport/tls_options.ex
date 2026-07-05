defmodule AshIntegration.Transport.TlsOptions do
  @moduledoc false
  # Shared builder for verified-by-default TLS client options, used by every
  # transport that opens a TLS connection to an operator-configured endpoint —
  # Kafka (list-valued `ssl:` handed straight to kpro) and SMTP (`tls_options`
  # passed through Swoosh's SMTP adapter to gen_smtp).
  #
  # Secure-by-default with a per-connection, auditable opt-out, mirroring
  # `Transport.Egress`: the DEFAULT verifies the certificate chain AND the
  # hostname (verify_peer + the HTTPS `pkix_verify_hostname_match_fun`, which is
  # what turns chain validation into hostname validation — verify_peer ALONE does
  # not check the hostname). An operator on an internal/firewalled broker or relay
  # with a self-signed or absent cert opts THAT ONE connection out by storing
  # `verify: :verify_none`; there is deliberately no global disable switch.
  #
  # Trust anchor: the OS trust store via `:public_key.cacerts_get()` (OTP 28, no
  # castore needed), unless a per-connection `cacertfile` points at a private-CA
  # bundle. `sni` overrides the handshake server name for brokers that front a
  # different cert CN.

  # A bounded chain depth keeps a pathological cert chain from ballooning the
  # verification work; 3 covers root → intermediate → leaf with headroom.
  @depth 3

  @doc false
  # Build the ssl option list from a config struct/map exposing `:verify` and,
  # optionally, `:cacertfile` and `:sni`. `verify_none` is the explicit, chosen
  # opt-out (no chain or hostname check); `verify_peer` is the verified default.
  @spec build(map()) :: keyword()
  def build(%{verify: :verify_none}), do: [verify: :verify_none]

  def build(%{verify: :verify_peer} = opts) do
    [
      verify: :verify_peer,
      depth: @depth,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
    |> put_trust_store(opts)
    |> maybe_put_sni(opts)
  end

  # A private-CA bundle (when configured) REPLACES the OS trust store — you point
  # at exactly the CA that signed the internal broker/relay, not both.
  defp put_trust_store(ssl_opts, opts) do
    case cacertfile(opts) do
      nil -> Keyword.put(ssl_opts, :cacerts, :public_key.cacerts_get())
      path -> Keyword.put(ssl_opts, :cacertfile, String.to_charlist(path))
    end
  end

  defp cacertfile(opts) do
    case Map.get(opts, :cacertfile) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp maybe_put_sni(ssl_opts, opts) do
    case Map.get(opts, :sni) do
      sni when is_binary(sni) and sni != "" ->
        Keyword.put(ssl_opts, :server_name_indication, String.to_charlist(sni))

      _ ->
        ssl_opts
    end
  end
end
