defmodule AshIntegration.Transport.Signing do
  @moduledoc """
  Outbound payload signing.

  The transports call `run/2` with the connection's `signing` union value and a
  send-time `ctx`; it loads (decrypts) the scheme's secret and dispatches to the
  pure `compute/2` engine:

    * `run/2` — load the `signing` union (decrypt the secret), then `compute/2`,
      classifying a `custom` script failure as a `:transport` error.
    * `compute/2` — the pure engine. Dispatches on a signing *scheme* (`:none` /
      `{:stripe, …}` / `{:custom, …}`) and returns the headers (and, for `custom`,
      any body/url change) to apply. The secret is plaintext here — never placed in
      the runtime sandbox — and the library performs the keyed MAC between the
      author's pure callbacks. See `design/configurable-signing.md`.
  """

  alias AshIntegration.Outbound.Delivery.Transform.Runtime
  alias AshIntegration.Transport.Utils

  @type scheme ::
          :none
          | {:stripe, %{required(:secret) => binary(), required(:header_name) => binary()}}
          | {:custom, custom_opts()}

  @type custom_opts :: %{
          required(:secret) => binary(),
          required(:source) => binary(),
          required(:runtime) => atom(),
          required(:algorithm) => :sha256 | :sha1 | :sha512,
          required(:encoding) => :hex | :base64 | :base64url
        }

  @typedoc """
  What `compute/2` asks the transport to apply:

    * `headers` — `{name, value}` pairs to merge (library-owned, win the de-dup)
    * `body` — `:keep` (send the exact signed bytes) or replacement wire bytes
    * `url` — `:keep` or a replacement absolute URL
  """
  @type applied :: %{
          headers: [{String.t(), String.t()}],
          body: :keep | binary(),
          url: :keep | String.t()
        }

  @doc """
  Load (decrypt) the `signing` union value and compute the signing outcome for
  `ctx`. Returns `{:ok, t:applied/0}`, or a **classified** `{:error, map()}` (a
  `:transport` failure) when the secret can't be decrypted or a `custom` script
  raises / returns a bad shape — so the caller surfaces it to suspension rather
  than crashing the contract.
  """
  @spec run(term(), map()) :: {:ok, applied()} | {:error, map()}
  def run(signing, ctx) do
    with {:ok, scheme} <- load_scheme(signing) do
      case compute(scheme, ctx) do
        {:ok, applied} ->
          {:ok, applied}

        {:error, message} ->
          {:error,
           %{
             failure_class: :transport,
             error_message: "signing failed: #{message}",
             retryable: true
           }}
      end
    end
  end

  @doc """
  Decrypt a `signing` union value into the plaintext `t:scheme/0` `compute/2`
  takes. The secret is loaded LIVE here (never persisted decrypted, never in the
  sandbox); a decryption failure is a classified, non-retryable `:transport` error.
  """
  @spec load_scheme(term()) :: {:ok, scheme()} | {:error, map()}
  def load_scheme(nil), do: {:ok, :none}
  def load_scheme(%Ash.Union{type: :none}), do: {:ok, :none}

  def load_scheme(%Ash.Union{type: :stripe, value: stripe}) do
    with {:ok, stripe} <- Utils.load_secret(stripe, [:secret], "signing secret") do
      {:ok, {:stripe, %{secret: stripe.secret, header_name: stripe.header_name}}}
    end
  end

  def load_scheme(%Ash.Union{type: :custom, value: custom}) do
    with {:ok, custom} <- Utils.load_secret(custom, [:secret], "signing secret") do
      {:ok,
       {:custom,
        %{
          secret: custom.secret,
          source: custom.source,
          runtime: custom.runtime,
          algorithm: custom.algorithm,
          encoding: custom.encoding
        }}}
    end
  end

  @doc """
  Build the frozen `now` sub-context shared by every signing callback in one send
  attempt (and advanced fresh on the next). The sandbox has no clock, so the host
  supplies the timestamp in several formats.
  """
  @spec now_context() :: map()
  def now_context do
    dt = DateTime.utc_now()

    %{
      unix_seconds: DateTime.to_unix(dt, :second),
      unix_millis: DateTime.to_unix(dt, :millisecond),
      iso8601: iso8601(dt),
      rfc1123: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
    }
  end

  defp iso8601(dt) do
    dt
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
    |> String.replace_suffix("+00:00", "Z")
  end

  @doc """
  Compute the signing outcome for an already-loaded plaintext `scheme` against
  `ctx`. Pure (no decryption) — the unit-testable core. Returns `{:ok, t:applied/0}`
  or `{:error, message}` for a `custom` script that raises or returns a bad shape.
  """
  @spec compute(scheme(), map()) :: {:ok, applied()} | {:error, String.t()}
  def compute(:none, _ctx), do: {:ok, %{headers: [], body: :keep, url: :keep}}

  def compute({:stripe, %{secret: secret, header_name: header}}, ctx) do
    ts = ctx.now.unix_seconds
    sig = encode(mac(:sha256, secret, "#{ts}.#{ctx.body}"), :hex)
    # Lowercase the header name on the wire (HTTP header names are case-insensitive)
    # so it matches the library's lowercase wire-header convention and de-dups
    # cleanly against a transform-set header regardless of the casing the operator
    # typed in the form.
    {:ok, %{headers: [{String.downcase(header), "t=#{ts},v1=#{sig}"}], body: :keep, url: :keep}}
  end

  def compute({:custom, opts}, ctx) do
    ctx = Map.put_new(ctx, :body, "")
    # One signing session: the runtime compiles the source ONCE, then `call`
    # invokes individual callbacks on that compiled state (no re-parse), all under
    # one resource budget. The keyed MAC happens here in Elixir, between calls —
    # the secret never enters the sandbox.
    Runtime.sign_session(opts.runtime, opts.source, fn call -> pipeline(opts, ctx, call) end)
  end

  # ── custom pipeline (runs inside the session, threading `call`) ───────────────

  defp pipeline(opts, ctx, call) do
    with {:ok, digest} <- digest(opts, ctx, call),
         ctx = Map.merge(ctx, %{digest: digest.hex, digest_base64: digest.base64}),
         {:ok, sts} <- string_to_sign(ctx, call) do
      signature = encode(mac(opts.algorithm, opts.secret, sts), opts.encoding)
      placements(Map.put(ctx, :signature, signature), signature, call)
    end
  end

  # The body digest the author embeds in the string-to-sign. Defaults to a hash of
  # the exact wire body; an overriding `content` callback returns the precise
  # string to hash (so the library never has to dictate a canonicalization).
  defp digest(opts, ctx, call) do
    case call.("content", ctx) do
      {:ok, :undefined} -> {:ok, hashes(opts.algorithm, ctx.body)}
      {:ok, {:defined, s}} when is_binary(s) -> {:ok, hashes(opts.algorithm, s)}
      {:ok, {:defined, _}} -> {:error, "the signing `content` callback must return a string"}
      {:error, message} -> {:error, message}
    end
  end

  defp string_to_sign(ctx, call) do
    case call.("string_to_sign", ctx) do
      {:ok, :undefined} ->
        {:ok, "#{ctx.now.unix_seconds}.#{ctx.body}"}

      {:ok, {:defined, s}} when is_binary(s) ->
        {:ok, s}

      {:ok, {:defined, _}} ->
        {:error, "the signing `string_to_sign` callback must return a string"}

      {:error, message} ->
        {:error, message}
    end
  end

  # Placement callbacks are separate and optional: an absent `body` callback means
  # the cached wire bytes are sent verbatim (the bytes that were signed). When no
  # placement is given at all, the signature defaults to an `x-signature` header.
  defp placements(ctx, signature, call) do
    with {:ok, headers} <- placement_headers(ctx, call),
         {:ok, body} <- placement_body(ctx, call),
         {:ok, url} <- placement_url(ctx, call) do
      headers =
        if headers == [] and body == :keep and url == :keep,
          do: [{"x-signature", signature}],
          else: headers

      {:ok, %{headers: headers, body: body, url: url}}
    end
  end

  defp placement_headers(ctx, call) do
    case call.("headers", ctx) do
      {:ok, :undefined} -> {:ok, []}
      {:ok, {:defined, map}} when is_map(map) -> {:ok, header_list(map)}
      {:ok, {:defined, []}} -> {:ok, []}
      {:ok, {:defined, _}} -> {:error, "the signing `headers` callback must return a table"}
      {:error, message} -> {:error, message}
    end
  end

  defp placement_body(ctx, call) do
    case call.("body", ctx) do
      {:ok, :undefined} ->
        {:ok, :keep}

      {:ok, {:defined, term}} ->
        # Encode with the non-raising variant: a `body` table the runtime decodes
        # to something Jason can't serialize (e.g. a non-finite float) must come
        # back as a classified `{:error, _}`, not a `Jason.EncodeError` that
        # escapes `compute/2`/`run/2` past the failure taxonomy.
        case Jason.encode(term) do
          {:ok, json} ->
            {:ok, json}

          {:error, error} ->
            {:error,
             "the signing `body` callback returned an unencodable table: #{Exception.message(error)}"}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp placement_url(ctx, call) do
    case call.("url", ctx) do
      {:ok, :undefined} -> {:ok, :keep}
      {:ok, {:defined, url}} when is_binary(url) -> {:ok, url}
      {:ok, {:defined, _}} -> {:error, "the signing `url` callback must return a string"}
      {:error, message} -> {:error, message}
    end
  end

  defp header_list(map),
    do: Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)

  # ── primitives ──────────────────────────────────────────────────────────────

  defp hashes(algorithm, data) do
    raw = :crypto.hash(hash_alg(algorithm), data)
    %{hex: Base.encode16(raw, case: :lower), base64: Base.encode64(raw)}
  end

  defp mac(algorithm, secret, data), do: :crypto.mac(:hmac, hash_alg(algorithm), secret, data)

  defp hash_alg(:sha256), do: :sha256
  defp hash_alg(:sha1), do: :sha
  defp hash_alg(:sha512), do: :sha512

  defp encode(bin, :hex), do: Base.encode16(bin, case: :lower)
  defp encode(bin, :base64), do: Base.encode64(bin)
  defp encode(bin, :base64url), do: Base.url_encode64(bin)
end
