defmodule AshIntegration.Outbound.Wire.Transports.EmailTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntegration.Outbound.Wire.Transports.Email
  alias AshIntegration.Transport.EmailAdapter.Smtp

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

  # The descriptor is already normalized/validated by the resolver, so these
  # exercise the pure replay mapping (delivery descriptor → Swoosh.Email) and the
  # failure classification — no SMTP server needed, mirroring the Kafka transport's
  # `build_message/2` unit tests.
  defp connection(from \\ "bot@acme.com"),
    do: %{transport_config: %Ash.Union{type: :email, value: %{from: from}}}

  defp event(delivery), do: %{delivery: delivery}

  defp smtp(overrides) do
    params = Enum.into(overrides, %{relay: "1.1.1.1", port: 587, tls: :always})

    Smtp
    |> Ash.Changeset.for_create(:create, params)
    |> Ash.create!()
  end

  defp adapter_union(overrides), do: %Ash.Union{type: :smtp, value: smtp(overrides)}

  describe "build_email/2 replay mapping" do
    test "maps recipients, subject, both bodies, and wire headers" do
      delivery = %{
        "to" => ["a@x.com", "b@x.com"],
        "cc" => ["c@x.com"],
        "bcc" => ["d@x.com"],
        "subject" => "Order shipped",
        "html" => "<b>shipped</b>",
        "text" => "shipped",
        "headers" => %{"x-event-id" => "evt_1", "x-event-type" => "order.shipped"}
      }

      assert {:ok, email} = Email.build_email(connection(), event(delivery))

      assert email.subject == "Order shipped"
      assert email.html_body == "<b>shipped</b>"
      assert email.text_body == "shipped"
      assert email.to == [{"", "a@x.com"}, {"", "b@x.com"}]
      assert email.cc == [{"", "c@x.com"}]
      assert email.bcc == [{"", "d@x.com"}]
      assert email.headers["x-event-id"] == "evt_1"
      assert email.headers["x-event-type"] == "order.shipped"
    end

    test "uses the connection's from address by default" do
      assert {:ok, email} = Email.build_email(connection(), event(%{"to" => ["a@x.com"]}))
      assert email.from == {"", "bot@acme.com"}
    end

    test "a descriptor from address overrides the connection default" do
      delivery = %{"from" => "alerts@acme.com", "to" => ["a@x.com"]}
      assert {:ok, email} = Email.build_email(connection(), event(delivery))
      assert email.from == {"", "alerts@acme.com"}
    end

    test "splits a display-name sender into {name, address}" do
      conn = connection("Acme Notifications <bot@acme.com>")
      assert {:ok, email} = Email.build_email(conn, event(%{"to" => ["a@x.com"]}))
      assert email.from == {"Acme Notifications", "bot@acme.com"}
    end

    test "omits absent optional recipients and bodies rather than emitting blanks" do
      delivery = %{"to" => ["a@x.com"], "text" => "hi"}
      assert {:ok, email} = Email.build_email(connection(), event(delivery))
      assert email.cc == []
      assert email.bcc == []
      assert email.html_body == nil
      assert email.text_body == "hi"
    end
  end

  describe "classify_error/1 → two-level suspension mapping" do
    test "a permanent SMTP failure suspends the subscription (response, non-retryable)" do
      assert %{failure_class: :response, retryable: false, error_message: msg} =
               Email.classify_error({:permanent_failure, "mx.acme.com", "550 no such user"})

      assert msg =~ "550 no such user"
    end

    test "a temporary SMTP failure is a retryable response" do
      assert %{failure_class: :response, retryable: true} =
               Email.classify_error({:temporary_failure, "mx.acme.com", "451 greylisted"})
    end

    test "gen_smtp nests the reason under :retries_exceeded / :network_failure" do
      assert %{failure_class: :response, retryable: false} =
               Email.classify_error(
                 {:retries_exceeded, {:permanent_failure, "mx", "552 too big"}}
               )

      assert %{failure_class: :transport, retryable: true} =
               Email.classify_error({:network_failure, "mx", {:error, :econnrefused}})
    end

    test "a connection-level failure suspends the connection (transport, retryable)" do
      assert %{failure_class: :transport, retryable: true} =
               Email.classify_error(:timeout)

      assert %{failure_class: :transport, retryable: true} =
               Email.classify_error({:no_more_hosts, :nxdomain})
    end

    test "an auth/credential failure is a non-retryable transport error" do
      assert %{failure_class: :transport, retryable: false} =
               Email.classify_error(:no_credentials)
    end
  end

  # `adapter_config/2` folds the live SMTP credential into the gen_smtp config and
  # attaches verified-by-default `tls_options`. gen_smtp passes `tls_options`
  # through on both the implicit-SSL and STARTTLS-upgrade paths, so this is where
  # cert verification is switched on (or, per connection, off).
  describe "adapter_config/2 TLS options" do
    test "verify_peer with the HTTPS hostname match_fun and OS trust store by default" do
      assert {:ok, Swoosh.Adapters.SMTP, config} = Email.adapter_config(adapter_union([]), nil)

      tls_options = Keyword.fetch!(config, :tls_options)
      assert Keyword.get(tls_options, :verify) == :verify_peer
      assert Keyword.get(tls_options, :depth) == 3
      assert [match_fun: match_fun] = Keyword.get(tls_options, :customize_hostname_check)
      assert is_function(match_fun)
      assert Keyword.get(tls_options, :cacerts) == :public_key.cacerts_get()
    end

    test "verify_none yields only the chosen opt-out when explicitly selected" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(adapter_union(verify: :verify_none), nil)

      assert Keyword.fetch!(config, :tls_options) == [verify: :verify_none]
    end

    test "a valid cacert_pem AUGMENTS the OS trust store (roots ++ pasted DER)" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(adapter_union(cacert_pem: @ca_pem), nil)

      tls_options = Keyword.fetch!(config, :tls_options)
      assert Keyword.get(tls_options, :cacerts) == :public_key.cacerts_get() ++ ca_ders()
    end

    test "a blank cacert_pem falls back to OS roots only" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(adapter_union(cacert_pem: "   \n  "), nil)

      tls_options = Keyword.fetch!(config, :tls_options)
      assert Keyword.get(tls_options, :cacerts) == :public_key.cacerts_get()
    end

    test "an undecodable cacert_pem is a non-retryable TLS configuration error (delivery backstop)" do
      # Save-time validation blocks a bad paste; simulate a value that bypassed it
      # (legacy/corrupted data) by overriding the field on an otherwise-valid record.
      union = %Ash.Union{type: :smtp, value: %{smtp(cacert_pem: @ca_pem) | cacert_pem: "bad"}}

      assert {:error, %{failure_class: :transport, retryable: false, error_message: msg}} =
               Email.adapter_config(union, nil)

      assert msg =~ "SMTP TLS configuration error"
      assert msg =~ "cacert_pem"
    end

    test "verify_none ignores a bad cacert_pem (nothing is verified)" do
      union = %Ash.Union{
        type: :smtp,
        value: %{smtp(verify: :verify_none, cacert_pem: @ca_pem) | cacert_pem: "bad"}
      }

      assert {:ok, _adapter, config} = Email.adapter_config(union, nil)
      assert Keyword.fetch!(config, :tls_options) == [verify: :verify_none]
    end

    test "ssl/tls/auth pass through unchanged" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(adapter_union(ssl: true, tls: :never, auth: :always), nil)

      assert Keyword.get(config, :ssl) == true
      assert Keyword.get(config, :tls) == :never
      assert Keyword.get(config, :auth) == :always
    end
  end

  # A bad `cacert_pem` is rejected AT SAVE TIME (not only at delivery), so a bad
  # paste can't sit on a connection and park events on the first send.
  describe "cacert_pem save-time validation" do
    test "an undecodable cacert_pem is rejected on create" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Smtp
               |> Ash.Changeset.for_create(:create, %{
                 relay: "smtp.acme.com",
                 port: 587,
                 cacert_pem: "not a certificate"
               })
               |> Ash.create()

      assert Exception.message(error) =~ "cacert_pem"
    end

    test "a valid cacert_pem is accepted on create" do
      assert {:ok, %Smtp{}} =
               Smtp
               |> Ash.Changeset.for_create(:create, %{
                 relay: "smtp.acme.com",
                 port: 587,
                 cacert_pem: @ca_pem
               })
               |> Ash.create()
    end
  end

  describe "adapter_config/2 STARTTLS-downgrade warning" do
    test "warns once for tls: :if_available against a public relay" do
      union = adapter_union(relay: "1.1.1.1", tls: :if_available)

      log = capture_log(fn -> Email.adapter_config(union, nil) end)
      assert log =~ "tls: :if_available"
      assert log =~ "strip STARTTLS"
    end

    test "does NOT warn for tls: :if_available against an RFC1918 relay" do
      union = adapter_union(relay: "10.0.0.5", tls: :if_available)

      log = capture_log(fn -> Email.adapter_config(union, nil) end)
      refute log =~ "strip STARTTLS"
    end
  end
end
