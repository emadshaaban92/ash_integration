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
  Validate `url` against the configured egress policy.

  Returns `:ok` when the policy is disabled, the host is allow-listed, or every
  resolved address is public-routable; `{:error, reason}` (a human-readable
  string) otherwise — a malformed URL, an unresolvable host, or a blocked
  address.
  """
  @spec validate(String.t() | nil) :: :ok | {:error, String.t()}
  def validate(url) do
    if blocking?() do
      do_validate(url)
    else
      :ok
    end
  end

  defp do_validate(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        validate_host(host)

      _ ->
        {:error, "egress blocked: could not parse host from URL"}
    end
  end

  defp do_validate(_other), do: {:error, "egress blocked: missing URL"}

  defp validate_host(host) do
    if allow_listed?(host) do
      :ok
    else
      case resolve(host) do
        {:ok, addresses} -> check_addresses(host, addresses)
        {:error, reason} -> {:error, "egress blocked: cannot resolve #{host} (#{reason})"}
      end
    end
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
    do: {:error, "egress blocked: #{host} resolved to no addresses"}

  defp check_addresses(host, addresses) do
    case Enum.find(addresses, &blocked_address?/1) do
      nil ->
        :ok

      blocked ->
        {:error,
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
