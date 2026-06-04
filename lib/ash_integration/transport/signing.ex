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
  require Logger

  @spec signature(map(), String.t()) :: {:ok, String.t() | nil} | {:error, map()}
  def signature(%{signing_secret: nil}, _body), do: {:ok, nil}

  def signature(config, body) do
    with {:ok, config} <-
           AshIntegration.Transport.Utils.load_secret(config, [:signing_secret], "signing secret") do
      case secret_state(config.signing_secret) do
        {:sign, secret} ->
          timestamp = System.system_time(:second)

          signature =
            :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
            |> Base.encode16(case: :lower)

          {:ok, "t=#{timestamp},v1=#{signature}"}

        :blank ->
          # Present-but-blank: a signing_secret is set but is empty/whitespace.
          # Shipping UNSIGNED here silently is a security surprise — surface it
          # loudly (telemetry + warning) rather than signing with a blank key or
          # silently dropping the signature.
          warn_blank_secret()
          {:ok, nil}

        :none ->
          {:ok, nil}
      end
    end
  end

  @doc false
  # Classify a (decrypted) signing secret: a usable secret to sign with, a
  # present-but-blank secret (empty/whitespace — a misconfiguration), or no secret.
  # Pure, so the blank detection is unit-testable without a cloak round-trip.
  @spec secret_state(term()) :: {:sign, String.t()} | :blank | :none
  def secret_state(nil), do: :none

  def secret_state(secret) when is_binary(secret) do
    if String.trim(secret) == "", do: :blank, else: {:sign, secret}
  end

  def secret_state(_other), do: :none

  defp warn_blank_secret do
    :telemetry.execute([:ash_integration, :signing, :blank_secret], %{count: 1}, %{})

    Logger.warning(
      "AshIntegration: a connection has a present-but-empty signing_secret — the " <>
        "delivery is being sent UNSIGNED. Set a non-empty secret, or clear it entirely " <>
        "if signing is intentionally disabled."
    )
  end
end
