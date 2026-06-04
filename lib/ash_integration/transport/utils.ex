defmodule AshIntegration.Transport.Utils do
  @moduledoc """
  Transport-neutral helpers shared across the transports.

  Small, pure utilities used by the wire transports
  (`AshIntegration.Outbound.Wire.Transports.*`).
  """

  import Bitwise

  @doc """
  De-duplicate a `{name, value}` header list case-insensitively, keeping the
  **last** value for each name and that value's position.

  Callers pass headers ordered **low → high priority**, so the library's wire
  headers, auth, and signature — appended last — win over any colliding
  connection-configured custom header. Without this a duplicate name would be
  sent twice (Req and `:brod` both treat repeated names as multi-value), letting
  a custom header shadow or corrupt the wire contract (e.g. a second
  `x-event-type`).
  """
  @spec dedup_keep_last([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def dedup_keep_last(headers) do
    headers
    |> Enum.reverse()
    |> Enum.uniq_by(fn {name, _value} -> String.downcase(name) end)
    |> Enum.reverse()
  end

  @doc """
  Coerce an HTTP response body to a string for storage/logging. Binaries pass
  through untouched; otherwise we JSON-encode, falling back to `inspect/1`.
  """
  def body_to_string(body) when is_binary(body), do: body

  def body_to_string(body) do
    case Jason.encode(body) do
      {:ok, json} -> json
      {:error, _} -> inspect(body)
    end
  end

  # Header names whose VALUES are secret-bearing and must never be persisted to
  # the delivery log (the stored wire descriptor and any reflected response body).
  # Matched case-insensitively; a name is also treated as sensitive when it
  # contains "secret", "token", or "password".
  @sensitive_headers ~w(authorization proxy-authorization cookie set-cookie
                        x-signature signature x-api-key api-key x-auth-token)

  @max_error_len 300
  @max_response_body_len 4_096

  @doc """
  Whether a header name carries a secret value (matched case-insensitively).
  """
  @spec sensitive_header?(String.t()) :: boolean()
  def sensitive_header?(name) do
    down = String.downcase(to_string(name))
    down in @sensitive_headers or String.contains?(down, ["secret", "token", "password"])
  end

  @doc """
  Redact secret-bearing header values in the stored wire descriptor before it is
  copied into the delivery log's `request_payload`.

  The live `EventDelivery.delivery` snapshot keeps a transform-set `authorization`
  verbatim (it's the live auth override replayed on every retry) — only the audit
  COPY written to the log is redacted, so the secret never lands in a queryable
  log row.
  """
  @spec redact_descriptor(map() | nil) :: map() | nil
  def redact_descriptor(%{"headers" => headers} = descriptor) when is_map(headers) do
    redacted =
      Map.new(headers, fn {name, value} ->
        if sensitive_header?(name), do: {name, "[REDACTED]"}, else: {name, value}
      end)

    %{descriptor | "headers" => redacted}
  end

  def redact_descriptor(descriptor), do: descriptor

  @doc """
  Truncate a reflected response body for storage and mask anything that looks like
  a reflected secret header (`authorization: …`, `x-signature: …`). A hostile or
  buggy target can echo the request's auth/signature headers back in its body; we
  store at most #{@max_response_body_len} bytes with those values masked.
  """
  @spec redact_response_body(String.t() | nil) :: String.t() | nil
  def redact_response_body(nil), do: nil

  def redact_response_body(body) when is_binary(body) do
    body
    |> truncate(@max_response_body_len)
    |> mask_reflected_secrets()
  end

  defp mask_reflected_secrets(body) do
    # Value class `(?:\\.|[^"\r\n])+` consumes escaped quotes (`\"`) so a JSON
    # value containing one (`"token":"ab\"cd"`) is masked in full, not just up to
    # the escaped quote.
    Regex.replace(
      ~r/("?(?:authorization|proxy-authorization|x-signature|signature|x-api-key|api-key|cookie|set-cookie|x-auth-token)"?\s*[:=]\s*"?)((?:\\.|[^"\r\n])+)/i,
      body,
      "\\1[REDACTED]"
    )
  end

  @doc """
  Build a safe, bounded error string from an arbitrary failure `reason` for
  persistence to `last_error` / the delivery log.

  `inspect(reason)` on an Ash error, a struct, or a record can splat decrypted
  secrets or whole credential structs into a queryable column. This whitelists
  what survives: atoms, numbers and printable binaries pass through; exceptions
  and structs collapse to their module name; anything else is `(redacted)`. The
  common, useful network reasons (`:econnrefused`, `{:tls_alert, …}`) stay
  readable.
  """
  @spec scrub_reason(term()) :: String.t()
  def scrub_reason(reason), do: reason |> summarize_reason() |> truncate(@max_error_len)

  defp summarize_reason(reason) when is_atom(reason), do: inspect(reason)
  defp summarize_reason(reason) when is_number(reason), do: to_string(reason)

  defp summarize_reason(reason) when is_binary(reason) do
    if String.printable?(reason), do: reason, else: "(binary redacted)"
  end

  defp summarize_reason(%{__exception__: true} = exception),
    do: inspect(exception.__struct__)

  defp summarize_reason(%{__struct__: module}), do: inspect(module)

  defp summarize_reason(list) when is_list(list) do
    if Enum.all?(list, &simple_term?/1),
      do: inspect(Enum.map(list, &summarize_reason/1)),
      else: "(list redacted)"
  end

  defp summarize_reason(tuple) when is_tuple(tuple) do
    elements = Tuple.to_list(tuple)

    if Enum.all?(elements, &simple_term?/1),
      do: "{" <> Enum.map_join(elements, ", ", &summarize_reason/1) <> "}",
      else: "(redacted)"
  end

  defp summarize_reason(_other), do: "(redacted)"

  defp simple_term?(value), do: is_atom(value) or is_number(value) or is_binary(value)

  defp truncate(string, max) when byte_size(string) > max,
    do: binary_part(string, 0, max) <> "…(truncated)"

  defp truncate(string, _max), do: string

  @doc """
  Encode a stored delivery body/value (a decoded term) to the exact wire bytes,
  used by BOTH the transport that sends it and the live signer — so the signature
  is computed over precisely what goes on the wire (serializer parity).

  An empty or unset body (`nil`, or an empty map/list — which Lua can't tell
  apart) becomes `nil` (HTTP: no body) rather than the misleading `"{}"`/`"[]"`;
  callers that need an empty binary instead (Kafka, which always carries a record
  value) use `encode_body(term) || ""`. A present body is JSON-encoded.
  """
  def encode_body(value) when value in [nil, %{}, []], do: nil
  def encode_body(value), do: Jason.encode!(value)

  @doc """
  Parse a list of `"host:port"` broker strings into the `[{charlist_host,
  integer_port}]` shape `:brod` expects, defaulting the port to 9092 when
  omitted.
  """
  def parse_brokers(brokers) do
    Enum.map(brokers, fn broker ->
      case String.split(broker, ":", parts: 2) do
        [host, port] -> {String.to_charlist(host), String.to_integer(port)}
        [host] -> {String.to_charlist(host), 9092}
      end
    end)
  end

  @doc """
  Join a connection's `base_url` with a subscription's `path`. A nil/empty path
  yields the base URL unchanged (the single-endpoint webhook case); otherwise the
  two are joined with exactly one slash regardless of trailing/leading slashes.
  """
  def build_url(base_url, path) when path in [nil, ""], do: base_url

  def build_url(base_url, path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end

  @doc """
  Pick a Kafka partition for `key` over `count` partitions using **Kafka's
  standard murmur2 partitioner** — `toPositive(murmur2(key)) rem count`, the same
  scheme the Java client and librdkafka use by default.

  This matters for interop: if a non-AshIntegration producer writes the same key
  to the same topic, it must land on the **same** partition, or Kafka's per-key
  ordering guarantee is split across partitions. (A previous implementation used
  `:erlang.phash2`, which is internally consistent but does not match any other
  producer.)
  """
  @spec partition_for(String.t() | binary(), pos_integer()) :: non_neg_integer()
  def partition_for(_key, count) when count <= 1, do: 0
  def partition_for(key, count), do: rem(to_positive(murmur2(to_string(key))), count)

  @murmur2_seed 0x9747B28C
  @murmur2_m 0x5BD1E995
  @murmur2_r 24

  @doc """
  Kafka's `murmur2` hash of `data`, returned as a 32-bit unsigned integer (a port
  of `org.apache.kafka.common.utils.Utils.murmur2`).
  """
  @spec murmur2(binary()) :: non_neg_integer()
  def murmur2(data) when is_binary(data) do
    h = mask32(bxor(@murmur2_seed, byte_size(data)))

    {tail, h} = murmur2_body(data, h)

    h
    |> murmur2_tail(tail)
    |> murmur2_finalize()
  end

  # Body: consume 4 bytes (little-endian) at a time.
  defp murmur2_body(<<b0, b1, b2, b3, rest::binary>>, h) do
    k = b0 + (b1 <<< 8) + (b2 <<< 16) + (b3 <<< 24)
    k = imul32(k, @murmur2_m)
    k = mask32(bxor(k, k >>> @murmur2_r))
    k = imul32(k, @murmur2_m)

    h = imul32(h, @murmur2_m)
    h = mask32(bxor(h, k))
    murmur2_body(rest, h)
  end

  defp murmur2_body(tail, h), do: {tail, h}

  # Tail: the trailing <4 bytes (Java's fall-through switch).
  defp murmur2_tail(h, <<b0, b1, b2>>) do
    h = mask32(bxor(h, b2 <<< 16))
    h = mask32(bxor(h, b1 <<< 8))
    imul32(mask32(bxor(h, b0)), @murmur2_m)
  end

  defp murmur2_tail(h, <<b0, b1>>) do
    h = mask32(bxor(h, b1 <<< 8))
    imul32(mask32(bxor(h, b0)), @murmur2_m)
  end

  defp murmur2_tail(h, <<b0>>), do: imul32(mask32(bxor(h, b0)), @murmur2_m)
  defp murmur2_tail(h, <<>>), do: h

  defp murmur2_finalize(h) do
    h = mask32(bxor(h, h >>> 13))
    h = imul32(h, @murmur2_m)
    mask32(bxor(h, h >>> 15))
  end

  defp imul32(a, b), do: mask32(a * b)
  defp mask32(value), do: value &&& 0xFFFFFFFF
  defp to_positive(value), do: value &&& 0x7FFFFFFF

  @doc "Whether a Kafka/`:brod` produce error is worth retrying."
  def retryable_error?(:leader_not_available), do: true
  def retryable_error?(:not_leader_for_partition), do: true
  def retryable_error?(:broker_not_available), do: true
  def retryable_error?(:replica_not_available), do: true
  def retryable_error?(:preferred_leader_not_available), do: true
  def retryable_error?(:not_enough_replicas), do: true
  def retryable_error?(:not_enough_replicas_after_append), do: true
  def retryable_error?(:request_timed_out), do: true
  def retryable_error?(:timeout), do: true
  def retryable_error?(:network_exception), do: true
  def retryable_error?({:connect_error, _}), do: true
  def retryable_error?(:coordinator_not_available), do: true
  def retryable_error?(:not_coordinator), do: true
  # Catch-all: unknown errors default to non-retryable to surface permanent
  # failures quickly rather than burning through delivery attempts.
  def retryable_error?(_), do: false

  @doc """
  The transport types available in this environment. HTTP is always included;
  Kafka appears when `:brod` is loaded.
  """
  @spec available() :: [:http | :kafka]
  def available do
    [:http] ++ if(available?(:kafka), do: [:kafka], else: [])
  end

  @doc "Whether the given transport type is available (its optional deps are loaded)."
  @spec available?(atom()) :: boolean()
  def available?(:http), do: true
  def available?(:kafka), do: Code.ensure_loaded?(:brod)
  def available?(_), do: false

  @doc """
  Load encrypted/secret attributes for a transport, converting ANY failure into a
  classified, non-retryable `:transport` error instead of letting it raise.

  Transports decrypt credentials at send time via `Ash.load/3` — auth headers,
  the Kafka SASL password, the signing secret. A hard `{:ok, _} = Ash.load(...)`
  match turns a decryption/vault failure (an `{:error, _}` return OR a raised
  error) into a `MatchError` that escapes the transport's
  `{:error, %{failure_class: ...}}` contract: the delivery crashes with no
  `failure_class` recorded, so a connection with broken/rotated-bad auth retries
  forever and never auto-suspends (#76). Routing every secret load through
  here records it as `:transport`/`retryable: false` (a rotated-bad credential
  won't fix itself on retry), so the two-level suspension subsystem sees it.

  `context` is a human label for the secret (e.g. `"bearer token"`) used in the
  error message.
  """
  @spec load_secret(Ash.Resource.record(), list(), String.t()) ::
          {:ok, Ash.Resource.record()} | {:error, map()}
  def load_secret(record, load, context) do
    case Ash.load(record, load, domain: AshIntegration.domain()) do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, secret_error(context, reason)}
    end
  rescue
    exception -> {:error, secret_error(context, exception)}
  end

  defp secret_error(context, reason) do
    %{
      failure_class: :transport,
      error_message: "Failed to load #{context}: #{scrub_reason(reason)}",
      retryable: false
    }
  end
end
