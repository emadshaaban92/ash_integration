defmodule AshIntegration.Outbound.Wire.Transports.WhatsApp do
  @moduledoc false
  # Event-first WhatsApp transport over Meta's WhatsApp Business Cloud API — an
  # authenticated JSON POST to graph.facebook.com, mechanically an HTTP cousin but
  # a distinct transport because the message descriptor, config, and error
  # semantics are domain-specific. REPLAYS the snapshot-at-dispatch **semantic**
  # descriptor on `event.delivery` (`to`, `type`, and a `text` body or a
  # `template` name/language/components) and shapes the Graph JSON here in
  # `build_payload/1`. The single live secret carve-out is the WABA access token,
  # decrypted per send via `load_secret` and injected as a `Bearer` header — never
  # persisted in the descriptor, never logged.
  #
  # A non-2xx is classified on the HTTP status refined by Meta's `error.code` (see
  # `classify_error/2`): rate limits and 5xx are `:transport`/retryable (honoring
  # `Retry-After`), an
  # expired/blocked token is `:transport`/non-retryable (suspend the connection),
  # and undeliverable/re-engagement/template/param errors are `:response`/non-retryable
  # (suspend the subscription). NB: a 200 means Meta **accepted** the message, not
  # that it was delivered — true delivered/read status arrives via *inbound*
  # webhooks, which this outbound library does not handle.
  #
  # Modeling the provider as an `adapter` union (Meta Cloud now, Twilio later)
  # keeps a second provider a *config* choice, not a code fork — exactly like the
  # email transport's SMTP-vs-API split.

  @behaviour AshIntegration.Outbound.Wire.Transport

  alias AshIntegration.Transport.Egress
  alias AshIntegration.Transport.HttpWire
  alias AshIntegration.Transport.Utils

  @graph_host "https://graph.facebook.com"

  @impl true
  def deliver(connection, event) do
    %Ash.Union{type: :whatsapp, value: config} = connection.transport_config
    do_deliver(config.adapter, event)
  end

  defp do_deliver(%Ash.Union{type: :meta_cloud, value: adapter}, event) do
    payload = build_payload(event.delivery)
    url = graph_url(adapter)

    # The access token is the live carve-out: decrypted per send (a rotated token
    # auto-applies, a decrypt failure classifies as a non-retryable `:transport`
    # error instead of crashing the batcher) and injected as a Bearer header,
    # never into the stored descriptor.
    with {:ok, loaded} <- Utils.load_secret(adapter, [:access_token], "WhatsApp access token") do
      send_message(url, loaded.access_token, payload)
    end
  end

  defp graph_url(adapter),
    do: "#{@graph_host}/#{adapter.api_version}/#{adapter.phone_number_id}/messages"

  defp send_message(url, token, payload) do
    # Pin the graph host to a validated IP right before the send (the SSRF gate,
    # shared with the HTTP transport). A `:blocked` target is terminal; an
    # `:unresolvable` host is a transient DNS condition and stays retryable (see
    # `HttpWire.egress_error/2`).
    case Egress.pin(url) do
      {:ok, pinned_url, connect_options} ->
        do_send(pinned_url, token, payload, connect_options)

      {:error, category, reason} ->
        HttpWire.egress_error(category, reason)
    end
  end

  defp do_send(url, token, payload, connect_options) do
    # `json:` encodes the body and sets the `content-type: application/json`
    # request header; only the Bearer auth (the live secret) is added here.
    case HttpWire.request(
           __MODULE__,
           [
             method: :post,
             url: url,
             json: payload,
             headers: [{"authorization", "Bearer #{token}"}],
             retry: false,
             redirect: false
           ],
           connect_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, %{whatsapp_message_id: message_id(body), response_status: status}}

      {:ok, %Req.Response{status: status, body: body} = resp} ->
        error = classify_error(body, status)
        {:error, HttpWire.put_retry_after(error, error.retryable, resp)}

      {:error, %Req.TransportError{reason: reason}} ->
        HttpWire.transport_error(reason)

      {:error, reason} ->
        HttpWire.transport_error(reason)
    end
  end

  # The Graph message id (`wamid.XXX`) from a 200 body — the success metadata.
  defp message_id(%{"messages" => [%{"id" => id} | _]}), do: id
  defp message_id(_body), do: nil

  @doc false
  # The Graph JSON map for a stored semantic descriptor (no network). Exposed for
  # testing the shaping without hitting graph.facebook.com, mirroring
  # `Email.build_email/2` / `Kafka.build_message/2`. The descriptor was already
  # normalized/validated by the resolver (recipient is E.164 digits; a template
  # has a name + language, a text has a body), so this is a pure projection onto
  # the Cloud API request shape.
  @spec build_payload(map()) :: map()
  def build_payload(%{"type" => "text"} = descriptor) do
    %{
      "messaging_product" => "whatsapp",
      "recipient_type" => "individual",
      "to" => descriptor["to"],
      "type" => "text",
      "text" => %{"preview_url" => false, "body" => descriptor["text"]}
    }
  end

  def build_payload(%{"type" => "template"} = descriptor) do
    template = descriptor["template"] || %{}

    %{
      "messaging_product" => "whatsapp",
      "to" => descriptor["to"],
      "type" => "template",
      "template" =>
        drop_nils(%{
          "name" => template["name"],
          "language" => %{"code" => template["language"]},
          "components" => template["components"]
        })
    }
  end

  @doc false
  # Map a Meta Cloud API error response onto the two-level suspension contract,
  # keyed on `error.code` (verify against Meta's docs — the codes evolve):
  #
  #   * 4 / 17 / 32 — Meta's GENERIC Graph throttling codes (application / user /
  #     page request-limit reached). These arrive on an HTTP 400, so without an
  #     explicit clause they'd defer to the 400 status and classify non-retryable;
  #     they are throttling, not payload rejections, so treat them as retryable.
  #   * 429 / 130429 / 80007 / 131056 — rate / pair-rate limit → `:transport`,
  #     retryable (honor `Retry-After`): Meta is throttling, back off and retry.
  #   * 190 — access token expired/invalid → `:transport`, non-retryable: the
  #     connection's credential is broken, suspend it (won't fix on retry).
  #   * 368 — temporarily blocked for policy violations → `:transport`,
  #     non-retryable: suspend the connection until the block clears.
  #   * 131026 — undeliverable (recipient not on WhatsApp) → `:response`,
  #     non-retryable: this recipient is wrong, suspend the subscription.
  #   * 131047 — re-engagement / outside the 24h window → `:response`,
  #     non-retryable: needs a template, this exact send won't succeed.
  #   * 131051 — unsupported message type → `:response`, non-retryable.
  #   * 132000–132016 — template errors (not found / not approved / param
  #     mismatch / paused / disabled / policy) → `:response`, non-retryable.
  #   * 100 — invalid parameter → `:response`, non-retryable.
  #   * default unknown code → fall back to the HTTP status, classified exactly as
  #     the HTTP transport does (`HttpWire.retryable_status?/1`: 5xx and 408/429
  #     retry, every other 4xx/3xx does not). A deterministic 4xx carrying a
  #     new/unmapped code is therefore NON-retryable instead of burning retries.
  #
  # The HTTP status is the baseline; a RECOGNIZED Meta code refines it (e.g. a 400
  # bearing code 190 is still a non-retryable token failure). `error.code` is
  # coerced to an integer so a string like `"190"` matches the same branch as the
  # integer. Takes the decoded response body (a map with `error.code`/
  # `error.message`) or a raw string, plus the response status; exposed for
  # unit-testing the table.
  @spec classify_error(map() | binary() | nil, integer()) :: map()
  def classify_error(body, status) do
    {code, message} = error_fields(body)
    classify(coerce_code(code), message, status)
  end

  # A recognized code fixes the outcome regardless of the HTTP status.

  # Rate / pair-rate limits + Meta's generic Graph throttling codes (4/17/32) —
  # Meta is throttling, retry (Retry-After honored).
  defp classify(code, message, _status) when code in [4, 17, 32, 429, 130_429, 80_007, 131_056],
    do: transport_error(message, code, true)

  # Access token expired/invalid — the connection credential is broken.
  defp classify(190, message, _status), do: transport_error(message, 190, false)

  # Temporarily blocked for policy — suspend the connection until it clears.
  defp classify(368, message, _status), do: transport_error(message, 368, false)

  # Undeliverable recipient / re-engagement (24h window) / unsupported type /
  # invalid parameter — this exact payload won't succeed, suspend the subscription.
  defp classify(code, message, _status) when code in [131_026, 131_047, 131_051, 100],
    do: response_error(message, code)

  # Template errors (not found / not approved / param mismatch / paused / …).
  defp classify(code, message, _status) when code in 132_000..132_016,
    do: response_error(message, code)

  # No recognized code — defer to the HTTP status the way the HTTP transport does:
  # a 5xx or 408/429 retries, any other 4xx/3xx is a deterministic non-retryable
  # rejection (so an unmapped code doesn't burn retries until the health window
  # auto-suspends the connection).
  defp classify(_code, message, status),
    do: transport_error(message, nil, HttpWire.retryable_status?(status))

  # `error.code` arrives as an integer, but Meta sometimes sends it as a string
  # (`"190"`); coerce so it hits the same branch. Anything non-numeric → `nil`,
  # which lands on the status-driven default.
  defp coerce_code(code) when is_integer(code), do: code

  defp coerce_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp coerce_code(_code), do: nil

  defp response_error(message, code) do
    %{
      failure_class: :response,
      error_message: whatsapp_message(message, code),
      retryable: false
    }
  end

  defp transport_error(message, code, retryable) do
    %{
      failure_class: :transport,
      error_message: whatsapp_message(message, code),
      retryable: retryable
    }
  end

  defp whatsapp_message(nil, nil), do: "WhatsApp API error"
  defp whatsapp_message(nil, code), do: "WhatsApp API error (code #{code})"
  defp whatsapp_message(message, nil), do: "WhatsApp API error: #{Utils.scrub_reason(message)}"

  defp whatsapp_message(message, code),
    do: "WhatsApp API error (code #{code}): #{Utils.scrub_reason(message)}"

  # Pull `error.code` + `error.message` out of the response body. Meta returns a
  # JSON object; Req may hand us a decoded map or (for an odd content-type) a raw
  # string — tolerate both so a malformed body still classifies rather than crashes.
  defp error_fields(%{"error" => error}) when is_map(error),
    do: {error["code"], error["message"]}

  defp error_fields(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> error_fields(decoded)
      {:error, _} -> {nil, body}
    end
  end

  defp error_fields(_body), do: {nil, nil}

  defp drop_nils(map), do: :maps.filter(fn _key, value -> not is_nil(value) end, map)
end
