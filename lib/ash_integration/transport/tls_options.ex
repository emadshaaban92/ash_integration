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
  # castore needed). A per-connection `cacert_pem` (inline PEM certificate for a
  # private/self-signed CA, stored on the connection record — no side-channel
  # file) AUGMENTS the OS store rather than replacing it, so a connection that
  # mixes public-CA and private-CA endpoints still verifies both. `sni` overrides
  # the handshake server name for brokers that front a different cert CN.

  # A bounded chain depth keeps a pathological cert chain from ballooning the
  # verification work; 3 covers root → intermediate → leaf with headroom.
  @depth 3

  @doc false
  # Build the ssl option list from a config struct/map exposing `:verify` and,
  # optionally, `:cacert_pem` and `:sni`.
  #
  #   * `verify_none` is the explicit, chosen opt-out (no chain or hostname
  #     check); `cacert_pem` is ignored.
  #   * `verify_peer` is the verified default: OS roots, augmented with
  #     `cacert_pem`'s certificate(s) when present.
  #
  # Returns `{:ok, opts}`, or `{:error, message}` when `cacert_pem` is present but
  # not decodable to at least one PEM certificate — the bad PEM is surfaced to the
  # caller (which classifies it as a transport error) rather than silently
  # trusting nothing. A blank/whitespace-only `cacert_pem` is treated as "not set".
  @spec build(map()) :: {:ok, keyword()} | {:error, String.t()}
  def build(%{verify: :verify_none}), do: {:ok, [verify: :verify_none]}

  def build(%{verify: :verify_peer} = opts) do
    with {:ok, ssl_opts} <- put_trust_store(base_opts(), opts) do
      {:ok, maybe_put_sni(ssl_opts, opts)}
    end
  end

  @doc false
  # Validate a `cacert_pem` value the way `build/1` will consume it: nil/blank is
  # fine ("not set"), a non-blank value must decode to at least one PEM
  # certificate. Shared by the runtime builder and the save-time Ash validation
  # (`Validations.CacertPem`) so the accept criteria and the error message can't
  # drift between save time and delivery time. Returns `:ok` or `{:error, message}`.
  @spec validate_cacert_pem(term()) :: :ok | {:error, String.t()}
  def validate_cacert_pem(pem) do
    with {:ok, _ders} <- cacert_ders(pem), do: :ok
  end

  defp base_opts do
    [
      verify: :verify_peer,
      depth: @depth,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  # A private-CA cert (when pasted) AUGMENTS the OS trust store, so a connection
  # that reaches both public-CA and private-CA endpoints keeps verifying both.
  defp put_trust_store(ssl_opts, opts) do
    case cacert_ders(Map.get(opts, :cacert_pem)) do
      {:ok, []} -> {:ok, Keyword.put(ssl_opts, :cacerts, :public_key.cacerts_get())}
      {:ok, ders} -> {:ok, Keyword.put(ssl_opts, :cacerts, :public_key.cacerts_get() ++ ders)}
      {:error, message} -> {:error, message}
    end
  end

  # nil/blank → `{:ok, []}` (not set → OS roots only). Non-blank → decode the PEM
  # and keep the DER of every unencrypted `:Certificate` entry.
  defp cacert_ders(pem) when is_binary(pem) do
    case String.trim(pem) do
      "" -> {:ok, []}
      trimmed -> decode_certificates(trimmed)
    end
  end

  defp cacert_ders(_pem), do: {:ok, []}

  defp decode_certificates(pem) do
    case certificate_ders(pem) do
      [] ->
        {:error,
         "cacert_pem is set but contains no decodable PEM certificate — paste the " <>
           "private CA certificate in PEM form (a -----BEGIN CERTIFICATE----- block)"}

      ders ->
        {:ok, ders}
    end
  end

  # `pem_decode/1` raises on some malformed input; treat any failure as "no
  # certificates decoded" so `decode_certificates/1` reports it as an error
  # rather than crashing.
  defp certificate_ders(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.flat_map(fn
      {:Certificate, der, :not_encrypted} -> [der]
      _ -> []
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
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
