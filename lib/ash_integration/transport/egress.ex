defmodule AshIntegration.Transport.Egress do
  @moduledoc """
  SSRF egress control for outbound HTTP delivery.

  `base_url` is only shape-validated (`https?://…`), and a Lua transform can set
  `result.url` to an arbitrary absolute URL that bypasses the connection's
  `base_url` entirely. Without a guard, an operator-authored transform (or a
  compromised one) can point a delivery at a private/loopback/link-local address
  — the cloud-metadata endpoint (`169.254.169.254`), `localhost`, or an RFC-1918
  host behind the app — turning the delivery pipeline into an SSRF primitive.

  This module resolves the host of a candidate URL and rejects it when **any**
  resolved address falls in a blocked range. Because a hostname can resolve to
  several addresses (and DNS can rebind), every `:inet.getaddr`-resolved address
  is checked, not just the first.

  ## Configuration

  Blocking is **on by default**. Trusted internal deployments (delivering to a
  private mesh, a sidecar, an in-cluster service) opt out, or carve out specific
  hosts:

      config :ash_integration,
        egress: [
          block_private?: true,            # default; set false to allow all egress
          allow_hosts: ["metadata.internal"]  # exact host allowlist (escape hatch)
        ]

  `allow_hosts` matches the URL's host verbatim (case-insensitively) and skips the
  IP check for that host only — use it for a known-safe internal endpoint without
  disabling the guard globally.
  """

  import Bitwise

  @blocked_ipv4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @doc """
  Validate `url` against the configured egress policy, returning only a message.

  A thin wrapper over `classify/1` for callers (e.g. the send-time backstop) that
  want a human-readable reason but not the failure category. Returns `:ok` or
  `{:error, message}`.
  """
  @spec validate(String.t() | nil) :: :ok | {:error, String.t()}
  def validate(url) do
    case classify(url) do
      :ok -> :ok
      {:error, _category, message} -> {:error, message}
    end
  end

  @doc """
  Classify `url` against the configured egress policy.

  Returns `:ok` when the policy is disabled, the host is allow-listed, or every
  resolved address is public-routable. Otherwise `{:error, category, message}`,
  where `category` distinguishes a CONNECTIVITY failure from a POLICY rejection so
  the caller can route the two differently (a dead endpoint vs. an SSRF attempt):

    * `:unresolvable` — the host could not be resolved (DNS nxdomain, or it
      resolved to no addresses). A network/connectivity condition.
    * `:blocked` — the host resolved, but (at least) one address is non-public
      (private/loopback/link-local/metadata). An egress-policy rejection.
    * `:invalid` — the URL is missing or has no parseable host.
  """
  @spec classify(String.t() | nil) ::
          :ok | {:error, :unresolvable | :blocked | :invalid, String.t()}
  def classify(url) do
    if blocking?() do
      do_classify(url)
    else
      :ok
    end
  end

  @doc """
  Resolve `url`'s host ONCE, validate it, and return a request target pinned to the
  validated IP — so the address that is checked is exactly the address connected to.

  This is the actual DNS-rebinding defense. `classify/1`/`validate/1` resolve the
  host, but the HTTP client then resolves it AGAIN to connect, so a rebinding
  resolver can return a public IP to the check and a private one to the client.
  Handing the client a literal IP (plus the original hostname for TLS SNI, cert
  verification, and the `Host` header) leaves no second resolution to subvert.

  Returns:

    * `{:ok, request_url, connect_options}` — issue the request to `request_url`,
      merging `connect_options` (e.g. `[hostname: host]`). Nothing is pinned (the
      original URL, `[]`) when the policy is off, the host is allow-listed, or the
      URL is already an IP literal.
    * `{:error, category, message}` — the same categories as `classify/1`.
  """
  @spec pin(String.t() | nil) ::
          {:ok, String.t(), keyword()}
          | {:error, :unresolvable | :blocked | :invalid, String.t()}
  def pin(url) do
    if blocking?() do
      do_pin(url)
    else
      {:ok, url, []}
    end
  end

  @doc """
  True when `host` (an IP literal or a hostname) is confined to internal address
  space — every address it resolves to is private, loopback, link-local, or
  otherwise non-public-routable by the same classification `classify/1` uses.

  Reuses the module's address classification rather than re-deriving CIDR checks,
  so callers that treat internal endpoints differently (e.g. relaxing a warning
  for a firewalled SMTP relay) stay consistent with the egress policy. A host
  that resolves to *any* public address — or that can't be resolved at all — is
  NOT internal (returns `false`), erring toward the internet-facing treatment.
  """
  @spec internal_host?(String.t() | nil) :: boolean()
  def internal_host?(host) when is_binary(host) and host != "" do
    case resolve(host) do
      {:ok, [_ | _] = addresses} -> Enum.all?(addresses, &blocked_address?/1)
      _ -> false
    end
  end

  def internal_host?(_host), do: false

  defp do_classify(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        classify_host(host)

      _ ->
        {:error, :invalid, "egress blocked: could not parse host from URL"}
    end
  end

  defp do_classify(_other), do: {:error, :invalid, "egress blocked: missing URL"}

  defp classify_host(host) do
    if allow_listed?(host) do
      :ok
    else
      case resolve(host) do
        {:ok, addresses} ->
          check_addresses(host, addresses)

        {:error, reason} ->
          {:error, :unresolvable, "egress blocked: cannot resolve #{host} (#{reason})"}
      end
    end
  end

  defp do_pin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) and host != "" ->
        pin_host(url, uri, host)

      _ ->
        {:error, :invalid, "egress blocked: could not parse host from URL"}
    end
  end

  defp do_pin(_other), do: {:error, :invalid, "egress blocked: missing URL"}

  # Allow-listed hosts skip the IP check, so there is nothing validated to pin to.
  defp pin_host(url, uri, host) do
    if allow_listed?(host), do: {:ok, url, []}, else: pin_unlisted(url, uri, host)
  end

  defp pin_unlisted(url, uri, host) do
    case :inet.parse_address(String.to_charlist(host)) do
      # An IP literal needs no DNS, so there is no rebinding to defend against.
      {:ok, address} -> pin_literal(url, host, address)
      {:error, _} -> pin_resolved(uri, host)
    end
  end

  defp pin_literal(url, host, address) do
    with :ok <- check_addresses(host, [address]), do: {:ok, url, []}
  end

  # Validate EVERY resolved address, then connect to the first — the exact address
  # checked — carrying the hostname for SNI, cert verification, and the `Host` header.
  defp pin_resolved(uri, host) do
    case resolve(host) do
      {:error, reason} ->
        {:error, :unresolvable, "egress blocked: cannot resolve #{host} (#{reason})"}

      {:ok, addresses} ->
        with :ok <- check_addresses(host, addresses) do
          {:ok, pinned_url(uri, hd(addresses)), [hostname: host]}
        end
    end
  end

  # Swap the host for the validated IP, preserving scheme/port/path. IPv6 is bracketed.
  defp pinned_url(uri, address) do
    literal = to_string(:inet.ntoa(address))
    host_for_url = if tuple_size(address) == 8, do: "[#{literal}]", else: literal
    URI.to_string(%{uri | host: host_for_url, authority: nil})
  end

  # An IP literal needs no DNS; a hostname resolves to every v4 + v6 address.
  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        case {:inet.getaddrs(charlist, :inet), :inet.getaddrs(charlist, :inet6)} do
          {{:error, r4}, {:error, _r6}} -> {:error, format_reason(r4)}
          {v4, v6} -> {:ok, ok_addrs(v4) ++ ok_addrs(v6)}
        end
    end
  end

  defp ok_addrs({:ok, addrs}), do: addrs
  defp ok_addrs({:error, _}), do: []

  defp check_addresses(host, []),
    do: {:error, :unresolvable, "egress blocked: #{host} resolved to no addresses"}

  defp check_addresses(host, addresses) do
    case Enum.find(addresses, &blocked_address?/1) do
      nil ->
        :ok

      blocked ->
        {:error, :blocked,
         "egress blocked: #{host} resolves to non-public address " <>
           "#{:inet.ntoa(blocked)} (set `config :ash_integration, egress: [block_private?: false]` " <>
           "or add the host to `:allow_hosts` for trusted internal use)"}
    end
  end

  # ── Address classification ───────────────────────────────────────────────

  defp blocked_address?({a, b, c, d}) do
    Enum.any?(@blocked_ipv4, fn {network, prefix} -> in_cidr?({a, b, c, d}, network, prefix) end)
  end

  # IPv6: loopback (::1), unspecified (::), link-local (fe80::/10), unique-local
  # (fc00::/7), and IPv4-mapped (::ffff:0:0/96 → reuse the v4 rules).
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_address?({0, 0, 0, 0, 0, 0xFFFF, g, h}), do: blocked_address?(v4_of(g, h))
  defp blocked_address?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  defp blocked_address?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  defp blocked_address?(_address), do: false

  defp v4_of(g, h), do: {div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)}

  defp in_cidr?({a, b, c, d}, {na, nb, nc, nd}, prefix) do
    ip = :binary.decode_unsigned(<<a, b, c, d>>)
    net = :binary.decode_unsigned(<<na, nb, nc, nd>>)
    mask = mask32(prefix)
    (ip &&& mask) == (net &&& mask)
  end

  defp mask32(0), do: 0
  defp mask32(prefix), do: 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF

  # ── Config ────────────────────────────────────────────────────────────────

  defp blocking?, do: Keyword.get(egress_config(), :block_private?, true)

  defp allow_listed?(host) do
    down = String.downcase(host)

    egress_config()
    |> Keyword.get(:allow_hosts, [])
    |> Enum.any?(&(String.downcase(to_string(&1)) == down))
  end

  defp egress_config, do: Keyword.get(Application.get_all_env(:ash_integration), :egress, [])

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
