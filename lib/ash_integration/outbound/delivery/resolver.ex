defmodule AshIntegration.Outbound.Delivery.Resolver do
  @moduledoc """
  Resolves the **transport-shaped delivery descriptor** at dispatch/reprocess
  time.

  The transform mutates a global `result` table that is PRE-SEEDED (from the
  connection + subscription route + event) with the full delivery shape for the
  transport:

      HTTP  → result = %{ method, path, url, headers, body }
      Kafka → result = %{ topic, key, headers, value, timestamp }

  A no-op transform sends the pre-seeded defaults; the script only expresses
  overrides. `result = nil` skips the event.

  This module pre-seeds `result`, runs the Lua transform, then — unless the
  transform skipped — normalizes/validates the output and returns the wire
  payload to SNAPSHOT on the event (`event.delivery`). `body`/`value` are stored
  as the decoded TERM (not pre-serialized bytes); delivery encodes them once and
  signs over those exact bytes. Delivery replays the snapshot for the static wire
  payload (body/headers/routing), so retries send the same body/headers/routing.

  Two LIVE carve-outs, resolved at delivery (NOT here, NOT in the sandbox, NOT in
  the stored descriptor):

    * **signature** — a send-time MAC over the encoded body. Computed live so its
      `t=` reflects the actual send (the anti-replay timestamp), each attempt
      fresh, and a rotated secret auto-applies without reprocess.
    * **`Authorization`/auth** — the decrypted credential, injected live from the
      encrypted connection (never persisted, never exposed to the sandbox).

  `result.headers` is pre-seeded with the wire-metadata headers, `content-type`,
  and the connection's static headers — ALL overridable and removable.

  Returns `{:ok, descriptor}`, `:skip`, or `{:error, message}` (the transform
  raised or produced an invalid descriptor → the event parks).
  """

  alias AshIntegration.Outbound.Delivery.LuaSandbox
  alias AshIntegration.Transport.Egress
  alias AshIntegration.Transport.Utils
  alias AshIntegration.Outbound.Wire.Envelope

  @http_methods ~w(post put patch delete)

  @doc """
  Resolve `subscription`'s transform against the transform-input `envelope` for
  `connection`. `created_at` is the event's `DateTime` (the Kafka timestamp
  default). See the module doc for the return contract.
  """
  def resolve(connection, subscription, envelope, created_at) do
    %Ash.Union{type: transport, value: config} = connection.transport_config
    preseed = preseed(transport, config, subscription, envelope, created_at)
    # The transform is optional — a nil/blank script is a no-op (send the
    # pre-seeded defaults).
    script = subscription.transform_script || ""

    case LuaSandbox.execute(script, envelope, result: preseed) do
      {:ok, :skip} -> :skip
      {:ok, result} when is_map(result) -> finalize(transport, config, result, created_at)
      {:ok, _scalar} -> {:error, "transform must set `result` to a table"}
      {:error, message} -> {:error, message}
    end
  end

  # ── Pre-seed (config + route + event → the transform's starting `result`) ────

  defp preseed(:http, config, subscription, envelope, _created_at) do
    route = http_route(subscription.route_config)

    drop_nils(%{
      "method" => to_string(route.method || :post),
      "path" => route.path,
      "headers" => preseed_headers(config, envelope, &"x-#{&1}"),
      "body" => envelope.data
    })
  end

  defp preseed(:kafka, config, subscription, envelope, created_at) do
    drop_nils(%{
      "topic" => kafka_topic(subscription.route_config) || config.topic,
      "key" => to_string(envelope.event_key),
      "headers" => preseed_headers(config, envelope, & &1),
      "value" => envelope.data,
      "timestamp" => DateTime.to_unix(created_at, :millisecond)
    })
  end

  # The full header set the library sends EXCEPT the secret-derived signature
  # (added post-transform). Wire metadata + content-type win the case-insensitive
  # de-dup over a colliding connection-static header, so a static header can't
  # shadow the wire contract — but every entry here is still overridable/removable
  # by the transform. `render` prefixes the wire suffix per transport.
  defp preseed_headers(config, envelope, render) do
    static = Enum.map(config.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    wire =
      Enum.map(Envelope.wire_pairs(envelope), fn {s, v} -> {render.(s), v} end)

    (static ++ [{"content-type", "application/json"}] ++ wire)
    |> Utils.dedup_keep_last()
    |> Map.new()
  end

  # ── Finalize (transform output → stored wire descriptor, signed) ────────────

  defp finalize(:http, config, result, _created_at) do
    with {:ok, method} <- normalize_method(result["method"]),
         {:ok, headers} <- normalize_headers(result["headers"]),
         {:ok, url} <- resolve_url(config, result) do
      {:ok,
       %{
         "transport" => "http",
         "method" => method,
         "url" => url,
         "headers" => headers,
         "body" => normalize_body(Map.get(result, "body"))
       }}
    end
  end

  defp finalize(:kafka, _config, result, created_at) do
    with {:ok, topic} <- normalize_topic(result["topic"]),
         {:ok, headers} <- normalize_headers(result["headers"]),
         {:ok, timestamp} <- normalize_timestamp(result["timestamp"], created_at) do
      {:ok,
       %{
         "transport" => "kafka",
         "topic" => topic,
         "key" => to_string(result["key"]),
         "timestamp" => timestamp,
         "headers" => headers,
         "value" => normalize_body(Map.get(result, "value"))
       }}
    end
  end

  # A topic must be known at dispatch (subscription route, connection default, or
  # set by the transform). Fail here — parking the event with a clear error —
  # rather than letting it go `:pending` and fail late at the transport.
  defp normalize_topic(topic) when is_binary(topic) and topic != "", do: {:ok, topic}

  defp normalize_topic(_other),
    do: {:error, "no Kafka topic configured on the subscription or connection"}

  # `result.url`, when set, is a transform-authored absolute override that bypasses
  # the base_url + path join; otherwise the path is joined onto the connection's
  # base_url. The candidate URL is checked against the egress policy by source ×
  # category:
  #
  #   * base_url host UNRESOLVABLE — a connectivity condition on the connection's
  #     own endpoint, not an authoring bug. Left deliverable so the send-time egress
  #     gate fails it as a `:transport` error, bumping the connection counter and
  #     driving suspension instead of silently parking with the counter at 0.
  #   * anything else blocked PARKS (a build/authoring failure to fix + reprocess):
  #     a transform-set private/loopback/metadata URL (SSRF), a base_url resolving
  #     to a blocked address, or a malformed URL.
  #
  # Delivery pins + re-checks the URL at send time (see `Egress.pin/1`).
  defp resolve_url(config, result) do
    {url, override?} =
      case result["url"] do
        url when is_binary(url) and url != "" -> {url, true}
        _ -> {Utils.build_url(config.base_url, result["path"]), false}
      end

    case Egress.classify(url) do
      :ok -> {:ok, url}
      {:error, :unresolvable, _message} when not override? -> {:ok, url}
      {:error, _category, message} -> {:error, message}
    end
  end

  defp normalize_method(nil), do: {:ok, "post"}

  defp normalize_method(method) when is_binary(method) do
    down = String.downcase(method)
    if down in @http_methods, do: {:ok, down}, else: {:error, "invalid HTTP method: #{method}"}
  end

  defp normalize_method(other), do: {:error, "invalid HTTP method: #{inspect(other)}"}

  # A bare/empty Lua table decodes to `[]`; treat it as "no headers" (the
  # remove-everything case) rather than an error.
  defp normalize_headers(nil), do: {:ok, %{}}
  defp normalize_headers([]), do: {:ok, %{}}

  defp normalize_headers(headers) when is_map(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      name = to_string(key)

      with {:ok, value} <- header_value(key, value),
           :ok <- reject_control_chars(name, name),
           :ok <- reject_control_chars(name, value) do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_headers(other),
    do: {:error, "result.headers must be a table, got #{inspect(other)}"}

  defp header_value(_key, value) when is_binary(value), do: {:ok, value}
  defp header_value(_key, value) when is_number(value), do: {:ok, to_string(value)}
  defp header_value(_key, value) when is_boolean(value), do: {:ok, to_string(value)}
  defp header_value(key, _value), do: {:error, "result.headers[#{inspect(key)}] must be a string"}

  # Untrusted event data can flow into a transform-built header. A `\r`/`\n` (or
  # any C0 control / DEL) in a header name or value is a request-splitting vector
  # and crash-loops a delivery into a wedged lane (Mint raises on it). Reject it at
  # the resolver boundary so the delivery PARKS with a readable error instead.
  defp reject_control_chars(name, string) do
    if String.match?(string, ~r/[\x00-\x1f\x7f]/) do
      {:error, "result.headers[#{inspect(name)}] contains a control character (CR/LF/etc.)"}
    else
      :ok
    end
  end

  defp normalize_timestamp(nil, created_at),
    do: {:ok, DateTime.to_unix(created_at, :millisecond)}

  defp normalize_timestamp(ts, _created_at) when is_integer(ts), do: {:ok, ts}
  defp normalize_timestamp(ts, _created_at) when is_float(ts), do: {:ok, trunc(ts)}

  defp normalize_timestamp(other, _created_at) do
    {:error, "result.timestamp must be an integer (epoch ms), got #{inspect(other)}"}
  end

  # Store the body/value as the decoded TERM (encoding happens once at delivery).
  # An empty or unset body (nil, or an empty map/list — which Lua can't tell
  # apart) is normalized to `nil` so the stored descriptor reads cleanly
  # (`body: null` = "no body") and the transport's encoder treats it as empty.
  defp normalize_body(value) when value in [nil, %{}, []], do: nil
  defp normalize_body(value), do: value

  # ── Route helpers (the static, form-editable defaults layer) ────────────────

  defp http_route(%Ash.Union{type: :http, value: route}), do: route
  defp http_route(_), do: %{path: nil, method: nil}

  defp kafka_topic(%Ash.Union{type: :kafka, value: route}), do: route.topic
  defp kafka_topic(_), do: nil

  defp drop_nils(map), do: :maps.filter(fn _key, value -> not is_nil(value) end, map)
end
