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
end
