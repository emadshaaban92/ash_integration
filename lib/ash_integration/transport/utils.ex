defmodule AshIntegration.Transport.Utils do
  @moduledoc """
  Transport-neutral helpers shared across the transports.

  Small, pure utilities used by the wire transports
  (`AshIntegration.Outbound.Wire.Transports.*`).
  """

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

  @doc "Pick a Kafka partition for `key` via consistent hashing over `count` partitions."
  def partition_for(_key, 1), do: 0
  def partition_for(key, count), do: :erlang.phash2(key, count)

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
      error_message: "Failed to load #{context}: #{inspect(reason)}",
      retryable: false
    }
  end
end
