defmodule AshIntegration.Transport.Signing do
  @moduledoc """
  Shared HMAC-SHA256 payload signature generation for outbound integration transports.

  Produces signatures in the format `t=<timestamp>,v1=<hex_signature>`
  using the signing secret from the transport config. The signed payload is
  `"<timestamp>.<body>"`.
  """

  @doc """
  Returns `{:ok, signature}` with the bare signature value
  (`t=<timestamp>,v1=<hex>`) for `body`, `{:ok, nil}` when no signing secret is
  configured, or `{:error, %{failure_class: :transport, ...}}` when decrypting
  the secret fails, so the caller can surface it as a classified, non-retryable
  delivery failure rather than raising past the contract.

  Transports attach the value under the header name for their wire
  (`x-signature` on HTTP, `signature` on Kafka).
  """
  @spec signature(map(), String.t()) :: {:ok, String.t() | nil} | {:error, map()}
  def signature(%{signing_secret: nil}, _body), do: {:ok, nil}

  def signature(config, body) do
    with {:ok, config} <-
           AshIntegration.Transport.Utils.load_secret(config, [:signing_secret], "signing secret") do
      case config.signing_secret do
        secret when is_binary(secret) and secret != "" ->
          timestamp = System.system_time(:second)

          signature =
            :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
            |> Base.encode16(case: :lower)

          {:ok, "t=#{timestamp},v1=#{signature}"}

        _ ->
          {:ok, nil}
      end
    end
  end
end
