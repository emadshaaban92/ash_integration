defmodule AshIntegration.Outbound.Delivery.Resolver do
  @moduledoc """
  Resolves the **transport-shaped delivery descriptor** at dispatch/reprocess
  time.

  The transform is a function the author exposes — `transform(event, defaults)` —
  whose `defaults` argument is PRE-SEEDED (from the connection + subscription
  route + event) with the full delivery shape for the transport:

      HTTP     → defaults = %{ method, path, url, headers, body }
      Kafka    → defaults = %{ topic, key, headers, value, timestamp }
      Email    → defaults = %{ from, to, cc, subject, headers }
      WhatsApp → defaults = %{ to, type, text | template }

  The function returns the descriptor to deliver (a no-op exposing no `transform`
  sends the pre-seeded defaults; the function only expresses overrides). Returning
  `nil` skips the event.

  This module pre-seeds `defaults`, runs the transform, then — unless it
  skipped — normalizes/validates the returned descriptor and returns the wire
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

  `defaults.headers` is pre-seeded with the wire-metadata headers, `content-type`,
  and the connection's static headers — ALL overridable and removable.

  Returns `{:ok, descriptor, body_hash}`, `:skip`, or `{:error, message}` (the
  transform raised or produced an invalid descriptor → the event parks).
  `body_hash` is the canonical content hash for suppression (`Dedup`) — non-nil
  only for `suppress_unchanged` subscriptions, nil otherwise. A transform-set
  `result.dedup_on` is consumed here (as the hash target) and stripped from the
  descriptor, so it never reaches the wire.
  """

  alias AshIntegration.Outbound.Delivery.Dedup
  alias AshIntegration.Outbound.Delivery.Transform
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
    # pre-seeded defaults). The runtime is chosen per-subscription; fall back to
    # the default if the column is unset or wasn't loaded.
    script = subscription.transform_source || ""
    runtime = transform_runtime(subscription)

    case Transform.Runtime.execute(runtime, script, envelope, preseed) do
      {:ok, :skip} ->
        :skip

      {:ok, result} when is_map(result) ->
        # `dedup_on` is a control field, never a wire field — strip it from the
        # returned table before the descriptor is built so it can never reach the
        # transport, then use it (if set) as the suppression hash target.
        {dedup_on, result} = Map.pop(result, "dedup_on")

        with {:ok, descriptor} <- finalize(transport, config, result, created_at),
             {:ok, body_hash} <- maybe_hash(subscription, descriptor, dedup_on) do
          {:ok, descriptor, body_hash}
        end

      {:ok, _scalar} ->
        {:error, "transform must return a table or nil"}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Save-time **smoke check**: pre-seed and run the transform against `envelope`
  exactly as `resolve/4` would, but STOP before `finalize`. It answers one
  question — *does the script execute cleanly on this input?* — and nothing
  about the wire descriptor.

  The post-transform layers `resolve/4` applies (descriptor normalization and,
  inside it, the SSRF **egress** policy) are deliberately NOT run here: they are
  dispatch-time concerns, re-checked at send and meant to PARK a delivery, not
  to block a save. Folding egress in would also reject a perfectly valid script
  purely because its connection points at `localhost`. So this catches the
  script-author class — a raise, a denied `io`/`os` call, a `nil` index, a typo
  that runs, a non-table `result` — and leaves network/descriptor policy to
  dispatch.

  Returns `:ok` (the transform produced a table or skipped) or
  `{:error, message}` (it raised, hit a denied op, or returned a non-table).
  """
  def smoke(connection, subscription, envelope, created_at) do
    %Ash.Union{type: transport, value: config} = connection.transport_config
    preseed = preseed(transport, config, subscription, envelope, created_at)
    script = subscription.transform_source || ""
    runtime = transform_runtime(subscription)

    case Transform.Runtime.execute(runtime, script, envelope, preseed) do
      {:ok, :skip} -> :ok
      {:ok, result} when is_map(result) -> :ok
      {:ok, _scalar} -> {:error, "transform must return a table or nil"}
      {:error, message} -> {:error, message}
    end
  end

  defp transform_runtime(%{transform_runtime: runtime})
       when is_atom(runtime) and not is_nil(runtime),
       do: runtime

  defp transform_runtime(_subscription), do: Transform.Runtime.default_runtime()

  # Compute the canonical dedup hash only for `suppress_unchanged` subscriptions;
  # nil otherwise (the common case pays nothing). A non-encodable `dedup_on` is a
  # transform bug → `{:error, _}` so the delivery parks with a readable message
  # (the same trust-boundary treatment as other invalid transform output).
  defp maybe_hash(%{suppress_unchanged: true}, descriptor, dedup_on) do
    {:ok, Dedup.hash(Dedup.target(descriptor, dedup_on))}
  rescue
    e -> {:error, "dedup_on is not encodable: #{Exception.message(e)}"}
  end

  defp maybe_hash(_subscription, _descriptor, _dedup_on), do: {:ok, nil}

  # ── Pre-seed (config + route + event → the transform's `defaults` argument) ────

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

  defp preseed(:whatsapp, _config, subscription, _envelope, _created_at) do
    route = whatsapp_route(subscription.route_config)

    # No wire headers: the WhatsApp Cloud API carries no custom headers in the
    # message body, and the auth header is the live secret carve-out. A route with
    # a default template name seeds `type: "template"` and the template
    # name/language; the transform usually fills `to` and the template params (see
    # `finalize(:whatsapp, …)`'s `body_params` shorthand) from the event.
    template =
      case route.template_name do
        name when is_binary(name) and name != "" ->
          drop_nils(%{"name" => name, "language" => route.language})

        _ ->
          nil
      end

    drop_nils(%{
      "to" => route.to,
      "type" => template && "template",
      "template" => template
    })
  end

  defp preseed(:email, config, subscription, envelope, _created_at) do
    route = email_route(subscription.route_config)

    # No body/subject default: email is human-facing, so the transform renders the
    # subject and text/html body (and usually the recipients) from the event. The
    # route's static recipients/subject are the fallbacks it starts from. Wire
    # metadata renders as `x-`-prefixed mail headers, mirroring the HTTP transport.
    drop_nils(%{
      "from" => config.from,
      "to" => route.to,
      "cc" => route.cc,
      "subject" => route.subject,
      "headers" => preseed_headers(config, envelope, &"x-#{&1}")
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
         "topic" => topic,
         "key" => to_string(result["key"]),
         "timestamp" => timestamp,
         "headers" => headers,
         "value" => normalize_body(Map.get(result, "value"))
       }}
    end
  end

  defp finalize(:email, config, result, _created_at) do
    with {:ok, headers} <- normalize_headers(result["headers"]),
         {:ok, from} <- normalize_address(result["from"] || config.from, "from"),
         {:ok, to} <- normalize_recipients(result["to"], "to", required: true),
         {:ok, cc} <- normalize_recipients(result["cc"], "cc", required: false),
         {:ok, bcc} <- normalize_recipients(result["bcc"], "bcc", required: false),
         {:ok, subject} <- normalize_subject(result["subject"]),
         {:ok, html, text} <- normalize_bodies(result["html"], result["text"]) do
      {:ok,
       drop_nils(%{
         "from" => from,
         "to" => to,
         "cc" => cc,
         "bcc" => bcc,
         "subject" => subject,
         "html" => html,
         "text" => text,
         "headers" => headers
       })}
    end
  end

  # Build the **semantic** WhatsApp descriptor (transform-shaped, like HTTP stores
  # `body` as a term) — the transport turns it into the Graph JSON. A `template`
  # message carries `name` + `language` + a `components` array; the transform can
  # supply that array directly (the raw escape hatch for headers/buttons/media) or,
  # more ergonomically, a `body_params` list that we expand into a single `body`
  # component here. A `text` (session) message carries a plain body.
  defp finalize(:whatsapp, _config, result, _created_at) do
    with {:ok, to} <- normalize_phone(result["to"]),
         {:ok, type} <- normalize_whatsapp_type(result["type"], result),
         {:ok, payload} <- normalize_whatsapp_payload(type, result) do
      {:ok, Map.merge(%{"to" => to, "type" => type}, payload)}
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
    do: {:error, "the transform's headers must be a table, got #{inspect(other)}"}

  defp header_value(_key, value) when is_binary(value), do: {:ok, value}
  defp header_value(_key, value) when is_number(value), do: {:ok, to_string(value)}
  defp header_value(_key, value) when is_boolean(value), do: {:ok, to_string(value)}

  defp header_value(key, _value),
    do: {:error, "the transform's headers[#{inspect(key)}] must be a string"}

  # Untrusted event data can flow into a transform-built header. A `\r`/`\n` (or
  # any C0 control / DEL) in a header name or value is a request-splitting vector
  # and crash-loops a delivery into a wedged lane (Mint raises on it). Reject it at
  # the resolver boundary so the delivery PARKS with a readable error instead.
  defp reject_control_chars(name, string) do
    if String.match?(string, ~r/[\x00-\x1f\x7f]/) do
      {:error,
       "the transform's headers[#{inspect(name)}] contains a control character (CR/LF/etc.)"}
    else
      :ok
    end
  end

  defp normalize_timestamp(nil, created_at),
    do: {:ok, DateTime.to_unix(created_at, :millisecond)}

  defp normalize_timestamp(ts, _created_at) when is_integer(ts), do: {:ok, ts}
  defp normalize_timestamp(ts, _created_at) when is_float(ts), do: {:ok, trunc(ts)}

  defp normalize_timestamp(other, _created_at) do
    {:error, "the transform's timestamp must be an integer (epoch ms), got #{inspect(other)}"}
  end

  # ── Email normalization (recipients/subject/body, header-injection safe) ─────

  # An address (`from`) or a recipient carries a real risk the other transports
  # don't: a raw CR/LF injects arbitrary SMTP headers. Reject control chars on
  # every address, recipient, and the subject at this boundary so a transform
  # built from untrusted event data can't smuggle headers.
  defp normalize_address(value, field) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, "email delivery requires a #{field} address"}
      control_char?(trimmed) -> {:error, "the transform's #{field} contains a control character"}
      true -> {:ok, trimmed}
    end
  end

  defp normalize_address(nil, field),
    do:
      {:error,
       "email delivery requires a #{field} address (set it on the connection or transform)"}

  defp normalize_address(other, field),
    do: {:error, "the transform's #{field} must be a string, got #{inspect(other)}"}

  defp normalize_recipients(value, field, opts) do
    case recipient_list(value) do
      {:ok, []} ->
        if opts[:required],
          do: {:error, "email delivery requires at least one #{field} recipient"},
          else: {:ok, nil}

      {:ok, list} ->
        {:ok, list}

      {:error, bad} ->
        {:error, "the transform's #{field}[#{inspect(bad)}] must be a non-empty address string"}

      :error ->
        {:error, "the transform's #{field} must be a string or a list of strings"}
    end
  end

  # A single string is one recipient; a Lua array decodes to a list. Each entry
  # must be a non-empty, control-char-free string.
  defp recipient_list(nil), do: {:ok, []}
  defp recipient_list(value) when is_binary(value), do: recipient_list([value])

  defp recipient_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case classify_recipient(value) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, address} -> {:cont, {:ok, [address | acc]}}
        :error -> {:halt, {:error, value}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp recipient_list(_other), do: :error

  defp classify_recipient(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> :skip
      control_char?(trimmed) -> :error
      true -> {:ok, trimmed}
    end
  end

  defp classify_recipient(_other), do: :error

  defp normalize_subject(value) when is_binary(value) do
    cond do
      String.trim(value) == "" ->
        {:error, "email delivery requires a subject (set result.subject)"}

      control_char_no_tab?(value) ->
        {:error, "the transform's subject contains a control character"}

      true ->
        {:ok, value}
    end
  end

  defp normalize_subject(nil),
    do: {:error, "email delivery requires a subject (set result.subject)"}

  defp normalize_subject(other),
    do: {:error, "the transform's subject must be a string, got #{inspect(other)}"}

  # At least one of html/text must be present. Each, when set, must be a string.
  defp normalize_bodies(html, text) do
    with {:ok, html} <- normalize_body_part(html, "html"),
         {:ok, text} <- normalize_body_part(text, "text") do
      if is_nil(html) and is_nil(text) do
        {:error, "email delivery requires an html or text body"}
      else
        {:ok, html, text}
      end
    end
  end

  defp normalize_body_part(nil, _field), do: {:ok, nil}
  defp normalize_body_part("", _field), do: {:ok, nil}
  defp normalize_body_part(value, _field) when is_binary(value), do: {:ok, value}

  defp normalize_body_part(other, field),
    do: {:error, "the transform's #{field} body must be a string, got #{inspect(other)}"}

  defp control_char?(string), do: String.match?(string, ~r/[\x00-\x1f\x7f]/)
  # Subjects may legitimately contain a tab; still reject CR/LF and other controls.
  defp control_char_no_tab?(string), do: String.match?(string, ~r/[\x00-\x08\x0a-\x1f\x7f]/)

  # ── WhatsApp normalization (E.164 recipient, template/text, header-safe) ─────

  # The recipient must resolve to E.164 digits. A leading `+` is stripped (Meta
  # wants bare digits); anything else non-numeric — control chars included — parks
  # the delivery rather than reaching the wire. A number the transform set from
  # untyped event data is coerced to a string first.
  defp normalize_phone(value) when is_integer(value),
    do: normalize_phone(Integer.to_string(value))

  defp normalize_phone(value) when is_binary(value) do
    digits = value |> String.trim() |> String.trim_leading("+")

    cond do
      digits == "" ->
        {:error, "whatsapp delivery requires a recipient (set result.to)"}

      String.match?(digits, ~r/\A[0-9]{5,15}\z/) ->
        {:ok, digits}

      true ->
        {:error,
         "the transform's to must be an E.164 phone number (digits only), got #{inspect(value)}"}
    end
  end

  defp normalize_phone(nil),
    do:
      {:error, "whatsapp delivery requires a recipient (set result.to on the route or transform)"}

  defp normalize_phone(other),
    do: {:error, "the transform's to must be a phone number string, got #{inspect(other)}"}

  # An explicit `type` wins; otherwise infer from what the transform supplied (a
  # `template` table or `text` body) so the ergonomic path doesn't force a
  # redundant `type`. With neither, park with a clear error.
  defp normalize_whatsapp_type(type, _result) when type in ["text", "template"], do: {:ok, type}

  defp normalize_whatsapp_type(nil, result) do
    cond do
      is_map(result["template"]) -> {:ok, "template"}
      is_binary(result["text"]) -> {:ok, "text"}
      true -> {:error, "whatsapp delivery requires a type (\"text\" or \"template\")"}
    end
  end

  defp normalize_whatsapp_type(other, _result),
    do:
      {:error,
       "invalid whatsapp message type: #{inspect(other)} (expected \"text\" or \"template\")"}

  defp normalize_whatsapp_payload("text", result) do
    case result["text"] do
      text when is_binary(text) ->
        if String.trim(text) == "",
          do: {:error, "whatsapp text delivery requires a non-empty text body"},
          else: {:ok, %{"text" => text}}

      nil ->
        {:error, "whatsapp text delivery requires a text body (set result.text)"}

      other ->
        {:error, "the transform's text must be a string, got #{inspect(other)}"}
    end
  end

  defp normalize_whatsapp_payload("template", result) do
    template = result["template"] || %{}

    with :ok <- require_map(template, "template"),
         {:ok, name} <- require_template_field(template["name"], "name"),
         {:ok, language} <- require_template_field(template["language"], "language"),
         {:ok, components} <- normalize_components(template) do
      {:ok,
       %{
         "template" =>
           drop_nils(%{"name" => name, "language" => language, "components" => components})
       }}
    end
  end

  defp require_map(value, _field) when is_map(value), do: :ok

  defp require_map(_value, field),
    do: {:error, "the transform's #{field} must be a table, got a non-table value"}

  defp require_template_field(value, _field) when is_binary(value) and value != "",
    do: {:ok, value}

  defp require_template_field(_value, field),
    do: {:error, "whatsapp template delivery requires a #{field} (set result.template.#{field})"}

  # `components` (a raw Graph array) is the escape hatch for header/button/media
  # components and passes through untouched. Otherwise the ergonomic `body_params`
  # list expands into a single `body` component of text parameters. Neither → a
  # parameter-free template (no components).
  defp normalize_components(%{"components" => components}) when is_list(components),
    do: {:ok, components}

  defp normalize_components(%{"components" => other}) when not is_nil(other),
    do: {:error, "the transform's template.components must be a list, got #{inspect(other)}"}

  defp normalize_components(%{"body_params" => params}) when is_list(params) do
    # Each entry must be a scalar that renders to a Graph text parameter. A Lua
    # table (decoded as a map) or a list would make `to_string/1` RAISE out of the
    # resolver — the one invalid-output path that wouldn't park — and a list of
    # small integers would silently coerce into a charlist. Validate here so bad
    # output PARKS with a readable reason like every other invalid descriptor.
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case body_param_text(param) do
        {:ok, text} -> {:cont, {:ok, [%{"type" => "text", "text" => text} | acc]}}
        :error -> {:halt, {:error, "body_params entries must be strings/numbers/booleans"}}
      end
    end)
    |> case do
      {:ok, parameters} ->
        {:ok, [%{"type" => "body", "parameters" => Enum.reverse(parameters)}]}

      {:error, _message} = error ->
        error
    end
  end

  defp normalize_components(%{"body_params" => other}) when not is_nil(other),
    do: {:error, "the transform's template.body_params must be a list, got #{inspect(other)}"}

  defp normalize_components(_template), do: {:ok, nil}

  # A body parameter is a scalar rendered to text. Anything else (a table/map or a
  # list) is rejected so the delivery parks instead of `to_string/1` raising.
  defp body_param_text(value) when is_binary(value), do: {:ok, value}
  defp body_param_text(value) when is_boolean(value), do: {:ok, to_string(value)}
  defp body_param_text(value) when is_number(value), do: {:ok, to_string(value)}
  defp body_param_text(_value), do: :error

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

  defp email_route(%Ash.Union{type: :email, value: route}), do: route
  defp email_route(_), do: %{to: nil, cc: nil, subject: nil}

  defp whatsapp_route(%Ash.Union{type: :whatsapp, value: route}), do: route
  defp whatsapp_route(_), do: %{to: nil, template_name: nil, language: nil}

  defp drop_nils(map), do: :maps.filter(fn _key, value -> not is_nil(value) end, map)
end
