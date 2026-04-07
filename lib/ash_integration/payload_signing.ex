defmodule AshIntegration.PayloadSigning do
  @moduledoc """
  Shared HMAC-SHA256 payload signature generation for outbound integration transports.

  Produces signatures in the format `t=<timestamp>,v1=<hex_signature>`
  using the signing secret from the transport config. The signed payload is
  `"<timestamp>.<body>"`.
  """

  @doc """
  Returns signature headers for the given config and body payload.

  The config must have a `:signing_secret` field (possibly encrypted via AshCloak).
  Returns an empty list when no signing secret is configured.
  """
  @spec signature_headers(map(), String.t()) :: [{String.t(), String.t()}]
  def signature_headers(%{signing_secret: nil}, _body), do: []

  def signature_headers(config, body) do
    {:ok, config} = Ash.load(config, [:signing_secret], domain: AshIntegration.domain())

    case config.signing_secret do
      secret when is_binary(secret) and secret != "" ->
        timestamp = System.system_time(:second)
        signed_payload = "#{timestamp}.#{body}"

        signature =
          :crypto.mac(:hmac, :sha256, secret, signed_payload)
          |> Base.encode16(case: :lower)

        [{"x-payload-signature", "t=#{timestamp},v1=#{signature}"}]

      _ ->
        []
    end
  end
end
