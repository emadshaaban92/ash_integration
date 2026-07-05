defmodule AshIntegration.Transport.HttpWire do
  @moduledoc false
  # Shared machinery for the HTTP-based wire transports (`Transports.Http` and
  # `Transports.WhatsApp` — WhatsApp's Cloud API is an authenticated JSON POST to
  # graph.facebook.com, mechanically an HTTP cousin). Both issue the request the
  # same way (`Req` with `retry: false`, `redirect: false`, the operator's
  # `req_options`, the egress pin's `connect_options`), classify a connection-level
  # failure as `:transport`, a blocked egress target as a non-retryable
  # `:transport`, and honor a server `Retry-After` on a retryable rejection. The
  # per-status vs per-error-code response classification stays in each transport
  # (HTTP keys on the status; WhatsApp keys on `error.code`).

  require Logger

  alias AshIntegration.Transport.Utils

  # Options the transport pins for SSRF safety and MUST NOT be overridable by the
  # operator's `req_options`. `Req` is last-wins and `req_options` is appended after
  # the transport's own `redirect: false`/`retry: false`, so an operator setting
  # `req_options: [redirect: true]` would silently re-enable redirect following and
  # let a 3xx to an internal address bypass the egress IP pin. Strip them (with a
  # warning) rather than let them win.
  @pinned_security_options [:redirect, :retry]

  @doc """
  Issue `request_options` through `Req`, folding in the operator's configured
  `req_options` and the egress pin's `connect_options`.

  `owner` is the calling transport module. In tests the configured `req_options`
  route through `Req.Test`; the stub owner is rewritten to `owner` so each
  transport is stubbed under its own module (`Req.Test.stub(Transports.WhatsApp,
  …)`). In production `req_options` is empty and this is a no-op.
  """
  @spec request(module(), keyword(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def request(owner, request_options, connect_options \\ []) do
    req_options =
      Application.get_env(:ash_integration, :req_options, [])
      |> put_test_owner(owner)
      |> strip_pinned_options()

    Req.request(request_options ++ merge_connect_options(req_options, connect_options))
  end

  defp strip_pinned_options(req_options) do
    case Keyword.take(req_options, @pinned_security_options) do
      [] ->
        req_options

      overridden ->
        Logger.warning(
          "AshIntegration: ignoring req_options #{inspect(Keyword.keys(overridden))} — " <>
            "redirect/retry are pinned by the transport (following a redirect would " <>
            "bypass the egress IP pin / SSRF protection)"
        )

        Keyword.drop(req_options, @pinned_security_options)
    end
  end

  defp put_test_owner(req_options, owner) do
    case Keyword.fetch(req_options, :plug) do
      {:ok, {Req.Test, _stub}} -> Keyword.put(req_options, :plug, {Req.Test, owner})
      _ -> req_options
    end
  end

  # Fold the pin's `connect_options` into any operator-set `req_options`, pin wins.
  defp merge_connect_options(req_options, []), do: req_options

  defp merge_connect_options(req_options, connect_options) do
    {existing, rest} = Keyword.pop(req_options, :connect_options, [])
    [{:connect_options, Keyword.merge(existing, connect_options)} | rest]
  end

  @doc """
  Which non-2xx statuses are worth retrying. A 5xx is a server-side hiccup; 408
  (Request Timeout) and 429 (Too Many Requests) are the only two 4xx codes that
  explicitly mean "the request was fine, try again later" — a transient, load- or
  timing-driven rejection, not a verdict on this payload. Every other 4xx and
  every 3xx is deterministic and non-retryable.
  """
  @spec retryable_status?(integer()) :: boolean()
  def retryable_status?(status), do: status >= 500 or status in [408, 429]

  @doc """
  On a RETRYABLE rejection, surface the server's own pacing —
  `Retry-After: <delay-seconds>` — as `retry_after_ms`, which the relay hands to
  the dispatcher to override the exponential backoff (clamped there, so a
  hostile/buggy header can't park a lane indefinitely). Only the integer-seconds
  form is parsed; the HTTP-date form (and any unparsable value) is ignored. A
  non-retryable rejection never carries it — there is no next attempt.
  """
  @spec put_retry_after(map(), boolean(), Req.Response.t()) :: map()
  def put_retry_after(metadata, false, _resp), do: metadata

  def put_retry_after(metadata, true, resp) do
    with [value | _] <- Req.Response.get_header(resp, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      Map.put(metadata, :retry_after_ms, seconds * 1000)
    else
      _ -> metadata
    end
  end

  @doc """
  Classify a connection-level failure (Req couldn't reach the target) as a
  retryable `:transport` error, mirroring the network-error default across both
  transports. The reason is scrubbed before it lands in a queryable column.
  """
  @spec transport_error(term()) :: {:error, map()}
  def transport_error(reason) do
    {:error,
     %{
       failure_class: :transport,
       error_message: "Network error: #{Utils.scrub_reason(reason)}",
       retryable: true
     }}
  end

  @doc """
  Classify an egress `pin`/`classify` rejection onto the transport contract,
  honoring the category `Egress` deliberately distinguishes:

    * `:unresolvable` — a transient DNS/connectivity condition (nxdomain, no
      addresses). Retryable `:transport`: the SAME failure is retryable when
      egress blocking is off (it surfaces as an ordinary Req transport error), so
      turning blocking ON must not make a DNS blip permanently fail the delivery.
    * `:blocked` / `:invalid` — a deterministic egress-policy rejection or an
      unparseable URL. Non-retryable `:transport`: it won't fix itself on retry.
  """
  @spec egress_error(:unresolvable | :blocked | :invalid, String.t()) :: {:error, map()}
  def egress_error(:unresolvable, reason) do
    {:error, %{failure_class: :transport, error_message: reason, retryable: true}}
  end

  def egress_error(_category, reason) do
    {:error, %{failure_class: :transport, error_message: reason, retryable: false}}
  end
end
