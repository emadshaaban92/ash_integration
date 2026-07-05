defmodule AshIntegration.Outbound.Wire.Transports.KafkaTlsTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Wire.Transports.Kafka

  # A self-signed CA used to exercise inline-PEM trust augmentation. Its DER is
  # what a valid `cacert_pem` should append to the OS roots.
  @ca_pem """
  -----BEGIN CERTIFICATE-----
  MIIDFTCCAf2gAwIBAgIUZO4GSuJ1OcLi4oOWOViF4Es0TRIwDQYJKoZIhvcNAQEL
  BQAwGjEYMBYGA1UEAwwPVGVzdCBQcml2YXRlIENBMB4XDTI2MDcwNTE3NDYwMFoX
  DTM2MDcwMjE3NDYwMFowGjEYMBYGA1UEAwwPVGVzdCBQcml2YXRlIENBMIIBIjAN
  BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtPXaYcbaLzCQhg/O3bMfVSHJGlOg
  /dDjJNLHq9MsuZVTPtDACOO5IZzyanBUV28Y9+vOu9raFMAogmiqZIs3rnw9wFs6
  Xg7A3cu41Au6OPbV73a5Wh1SIwXEJfosBB4cyvmy8Asr3rgR7v8ffl/3NeDwJ1cB
  DufNsaOpcsNXc+5TtXTuJNi2a4cr0b5oRRDnwyh/jy248cgGMtRYhV1kEYKzBseZ
  ldizq48o+nxRsnb7EPIqv7fXeJJVjJEXkWev7I1c8L5glUaqaiSNSxZZ+ZBHaL1n
  OKOtp6skKxn32NV5qzy5N1easQfOh/VAz92lGMlZSFxJJP7nKRYxCxA0hwIDAQAB
  o1MwUTAdBgNVHQ4EFgQUXCGO9s8i00JYyPI6zw8g3t1Hm/4wHwYDVR0jBBgwFoAU
  XCGO9s8i00JYyPI6zw8g3t1Hm/4wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
  AQsFAAOCAQEAAXicmRZhhjioE8jDO3ygQ9yvCf78UEwM4fT7C6JtXvLevlh3XY2B
  mg3CZrE3xviD79iylEjKOfMYpGYJaCWV0Bn0O9MUJz77YAiUPq2N1sgIgXH67PvI
  4ZKwVFyjmrzyeWCdHLxAwdZwwLPPRFE4jL0v9yirxlzjvdQq2cvPPnqNvWBmRr5P
  0CAVjczm3TUCegoPsZa7bUgGrj5MIG/9gHeJl1kbnjmSmC/EuMkMM8JcoeRZRs4n
  yGriKWtsN7nAZMvyDzlEZqWs+UcC3RJ1jIQOk0E8Hps0Lj+SYXsNrYUK43Wluw7N
  5xu4cd8JRg18EA8ecDj3lXYBqxsS/Xnufg==
  -----END CERTIFICATE-----
  """

  defp ca_ders do
    @ca_pem
    |> :public_key.pem_decode()
    |> Enum.map(fn {:Certificate, der, :not_encrypted} -> der end)
  end

  # `ssl_opts/1` is the list-valued `ssl:` option handed straight to kpro (a bare
  # `true` would collapse to verify_none). These exercise the verified-by-default
  # posture and the per-connection opt-out without a broker — the same variant
  # struct shape flows from both the :tls and :sasl_tls security branches.
  defp tls(overrides \\ %{}), do: Map.merge(%{verify: :verify_peer}, overrides)

  describe "ssl_opts/1 verified-by-default" do
    test "verify_peer with the HTTPS hostname match_fun and OS trust store by default" do
      assert {:ok, opts} = Kafka.ssl_opts(tls())

      assert Keyword.get(opts, :verify) == :verify_peer
      assert Keyword.get(opts, :depth) == 3

      # The hostname match_fun is what turns chain validation into hostname
      # validation — verify_peer ALONE does not check the hostname.
      assert [match_fun: match_fun] = Keyword.get(opts, :customize_hostname_check)
      assert is_function(match_fun)

      # OS trust store, verbatim, when no cacert_pem is configured.
      assert Keyword.get(opts, :cacerts) == :public_key.cacerts_get()
      refute Keyword.has_key?(opts, :server_name_indication)
    end

    test "a valid cacert_pem AUGMENTS the OS trust store (roots ++ pasted DER)" do
      assert {:ok, opts} = Kafka.ssl_opts(tls(%{cacert_pem: @ca_pem}))

      assert Keyword.get(opts, :cacerts) == :public_key.cacerts_get() ++ ca_ders()
      assert Keyword.get(opts, :verify) == :verify_peer
    end

    test "a blank cacert_pem falls back to OS roots only" do
      assert {:ok, opts} = Kafka.ssl_opts(tls(%{cacert_pem: "   \n  "}))

      assert Keyword.get(opts, :cacerts) == :public_key.cacerts_get()
    end

    test "an undecodable cacert_pem yields a clear error from the builder" do
      assert {:error, message} = Kafka.ssl_opts(tls(%{cacert_pem: "not a certificate"}))
      assert message =~ "cacert_pem"
    end

    test "an undecodable cacert_pem is a non-retryable TLS configuration error via the transport" do
      config = %{security: %Ash.Union{type: :tls, value: tls(%{cacert_pem: "not a certificate"})}}

      assert {:error, %{failure_class: :transport, retryable: false, error_message: msg}} =
               Kafka.build_client_config(config)

      assert msg =~ "Kafka TLS configuration error"
    end

    test "sni sets the handshake server name when provided" do
      assert {:ok, opts} = Kafka.ssl_opts(tls(%{sni: "broker.internal"}))

      assert Keyword.get(opts, :server_name_indication) == ~c"broker.internal"
    end
  end

  describe "ssl_opts/1 explicit opt-out" do
    test "verify_none yields only the chosen verify: :verify_none, no chain/hostname check" do
      assert {:ok, opts} = Kafka.ssl_opts(%{verify: :verify_none})

      assert opts == [verify: :verify_none]
    end

    test "verify_none ignores cacert_pem and sni (nothing is verified)" do
      assert {:ok, opts} = Kafka.ssl_opts(%{verify: :verify_none, cacert_pem: @ca_pem, sni: "y"})

      assert opts == [verify: :verify_none]
    end
  end
end
