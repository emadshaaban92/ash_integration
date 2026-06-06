defmodule AshIntegration.Transport.EgressTest do
  # Not async: these tests toggle the global `:egress` app env.
  use ExUnit.Case, async: false

  alias AshIntegration.Transport.Egress

  setup do
    original = Application.get_env(:ash_integration, :egress)
    Application.put_env(:ash_integration, :egress, block_private?: true)
    on_exit(fn -> restore(:egress, original) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ash_integration, key)
  defp restore(key, value), do: Application.put_env(:ash_integration, key, value)

  describe "validate/1 with blocking on (default)" do
    test "blocks the cloud metadata IP (169.254.169.254)" do
      assert {:error, message} = Egress.validate("http://169.254.169.254/latest/meta-data/")
      assert message =~ "egress blocked"
      assert message =~ "169.254.169.254"
    end

    test "blocks loopback" do
      assert {:error, message} = Egress.validate("http://127.0.0.1:9999/webhook")
      assert message =~ "egress blocked"
    end

    test "blocks RFC-1918 private ranges" do
      for ip <- ["10.0.0.5", "172.16.4.4", "192.168.1.1"] do
        assert {:error, _} = Egress.validate("https://#{ip}/hook"),
               "expected #{ip} to be blocked"
      end
    end

    test "blocks IPv6 loopback and link-local" do
      assert {:error, _} = Egress.validate("http://[::1]/")
      assert {:error, _} = Egress.validate("http://[fe80::1]/")
    end

    test "blocks an IPv4-mapped IPv6 loopback" do
      assert {:error, _} = Egress.validate("http://[::ffff:127.0.0.1]/")
    end

    test "allows a public-routable IP literal" do
      assert :ok = Egress.validate("https://1.1.1.1/hook")
    end

    test "rejects a URL with no parseable host" do
      assert {:error, message} = Egress.validate("not a url")
      assert message =~ "egress blocked"
    end

    test "rejects nil" do
      assert {:error, _} = Egress.validate(nil)
    end

    test "an explicit host allowlist bypasses the IP check" do
      Application.put_env(:ash_integration, :egress,
        block_private?: true,
        allow_hosts: ["127.0.0.1"]
      )

      assert :ok = Egress.validate("http://127.0.0.1:9999/webhook")
    end
  end

  describe "validate/1 with blocking off" do
    test "allows everything, including private/metadata addresses" do
      Application.put_env(:ash_integration, :egress, block_private?: false)
      assert :ok = Egress.validate("http://169.254.169.254/")
      assert :ok = Egress.validate("http://127.0.0.1:9999/webhook")
    end
  end

  # `classify/1` carries the failure CATEGORY so the resolver can tell a dead
  # endpoint (connectivity → suspend) from an SSRF attempt (authoring → park).
  describe "classify/1 (failure category)" do
    test "an unresolvable host is :unresolvable (a connectivity condition)" do
      # `.invalid` is reserved (RFC 6761) and never resolves.
      assert {:error, :unresolvable, message} =
               Egress.classify("https://wms.digitalhub.example.invalid/hook")

      assert message =~ "egress blocked"
      assert message =~ "cannot resolve"
    end

    test "a private/loopback/metadata address is :blocked (a policy rejection)" do
      # The stand-in for a transform-set `result.url` pointing at an internal host.
      assert {:error, :blocked, message} = Egress.classify("http://169.254.169.254/latest")
      assert message =~ "egress blocked"
      assert message =~ "169.254.169.254"

      assert {:error, :blocked, _} = Egress.classify("http://127.0.0.1:9999/webhook")
      assert {:error, :blocked, _} = Egress.classify("https://10.0.0.5/hook")
    end

    test "a malformed or missing URL is :invalid" do
      assert {:error, :invalid, _} = Egress.classify("not a url")
      assert {:error, :invalid, _} = Egress.classify(nil)
    end

    test "a public-routable address (or allow-listed host) is :ok" do
      assert :ok = Egress.classify("https://1.1.1.1/hook")
    end

    test "blocking off short-circuits to :ok regardless of category" do
      Application.put_env(:ash_integration, :egress, block_private?: false)
      assert :ok = Egress.classify("http://169.254.169.254/")
      assert :ok = Egress.classify("https://wms.digitalhub.example.invalid/hook")
    end
  end

  # `pin/1` resolves ONCE and hands back a target pinned to a validated IP, so the
  # checked address is the connected address — the actual DNS-rebinding defense.
  describe "pin/1 (DNS-rebinding-safe target)" do
    test "blocking off passes the URL through unpinned" do
      Application.put_env(:ash_integration, :egress, block_private?: false)
      assert {:ok, "https://example.com/hook", []} = Egress.pin("https://example.com/hook")
    end

    test "an allow-listed host is sent to the hostname, unpinned (its IP is trusted, not checked)" do
      Application.put_env(:ash_integration, :egress,
        block_private?: true,
        allow_hosts: ["metadata.internal"]
      )

      assert {:ok, "https://metadata.internal/x", []} = Egress.pin("https://metadata.internal/x")
    end

    test "a public IP literal is validated and passed through unchanged (no DNS to pin)" do
      assert {:ok, "https://1.1.1.1/hook", []} = Egress.pin("https://1.1.1.1/hook")
    end

    test "a blocked IP literal is rejected with its category" do
      assert {:error, :blocked, message} = Egress.pin("http://169.254.169.254/latest")
      assert message =~ "egress blocked"
    end

    test "a hostname resolving to a non-public address is :blocked (e.g. localhost → loopback)" do
      assert {:error, :blocked, _} = Egress.pin("http://localhost:9999/webhook")
    end

    test "an unresolvable hostname is :unresolvable" do
      assert {:error, :unresolvable, message} =
               Egress.pin("https://wms.digitalhub.example.invalid/hook")

      assert message =~ "cannot resolve"
    end

    test "a malformed or missing URL is :invalid" do
      assert {:error, :invalid, _} = Egress.pin("not a url")
      assert {:error, :invalid, _} = Egress.pin(nil)
    end

    test "a hostname is PINNED to a validated public IP, carrying the hostname for SNI/Host" do
      # Needs live DNS; the offline branches above cover the logic. Assert the pin
      # shape only when resolution is available.
      case :inet.getaddrs(~c"one.one.one.one", :inet) do
        {:ok, _addrs} ->
          assert {:ok, pinned, opts} = Egress.pin("https://one.one.one.one/hook")
          # The hostname is preserved for TLS SNI / cert verification / Host header...
          assert Keyword.fetch!(opts, :hostname) == "one.one.one.one"
          # ...while the connect URL host is now a literal IP, not the hostname.
          %URI{host: host, path: path} = URI.parse(pinned)
          assert {:ok, _ip} = :inet.parse_address(String.to_charlist(host))
          assert path == "/hook"

        {:error, _} ->
          :ok
      end
    end
  end
end
