defmodule AshIntegration.Outbound.Wire.Transports.KafkaTlsTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Wire.Transports.Kafka

  # `ssl_opts/1` is the list-valued `ssl:` option handed straight to kpro (a bare
  # `true` would collapse to verify_none). These exercise the verified-by-default
  # posture and the per-connection opt-out without a broker — the same variant
  # struct shape flows from both the :tls and :sasl_tls security branches.
  defp tls(overrides \\ %{}), do: Map.merge(%{verify: :verify_peer}, overrides)

  describe "ssl_opts/1 verified-by-default" do
    test "verify_peer with the HTTPS hostname match_fun and OS trust store by default" do
      opts = Kafka.ssl_opts(tls())

      assert Keyword.get(opts, :verify) == :verify_peer
      assert Keyword.get(opts, :depth) == 3

      # The hostname match_fun is what turns chain validation into hostname
      # validation — verify_peer ALONE does not check the hostname.
      assert [match_fun: match_fun] = Keyword.get(opts, :customize_hostname_check)
      assert is_function(match_fun)

      # OS trust store, not a file, when no cacertfile is configured.
      assert cacerts = Keyword.get(opts, :cacerts)
      assert is_list(cacerts) and cacerts != []
      refute Keyword.has_key?(opts, :cacertfile)
      refute Keyword.has_key?(opts, :server_name_indication)
    end

    test "cacertfile replaces the OS trust store when set" do
      opts = Kafka.ssl_opts(tls(%{cacertfile: "/etc/ssl/internal-ca.pem"}))

      assert Keyword.get(opts, :cacertfile) == ~c"/etc/ssl/internal-ca.pem"
      refute Keyword.has_key?(opts, :cacerts)
      assert Keyword.get(opts, :verify) == :verify_peer
    end

    test "a blank cacertfile falls back to the OS trust store" do
      opts = Kafka.ssl_opts(tls(%{cacertfile: ""}))

      assert Keyword.has_key?(opts, :cacerts)
      refute Keyword.has_key?(opts, :cacertfile)
    end

    test "sni sets the handshake server name when provided" do
      opts = Kafka.ssl_opts(tls(%{sni: "broker.internal"}))

      assert Keyword.get(opts, :server_name_indication) == ~c"broker.internal"
    end
  end

  describe "ssl_opts/1 explicit opt-out" do
    test "verify_none yields only the chosen verify: :verify_none, no chain/hostname check" do
      opts = Kafka.ssl_opts(%{verify: :verify_none})

      assert opts == [verify: :verify_none]
    end

    test "verify_none ignores cacertfile and sni (nothing is verified)" do
      opts = Kafka.ssl_opts(%{verify: :verify_none, cacertfile: "/x.pem", sni: "y"})

      assert opts == [verify: :verify_none]
    end
  end
end
