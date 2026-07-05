defmodule AshIntegration.Outbound.Wire.Transports.EmailTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntegration.Outbound.Wire.Transports.Email
  alias AshIntegration.Transport.EmailAdapter.Smtp

  # A stand-in adapter whose `deliver/2` raises the way gen_smtp's `mimemail` does
  # when a stray `Content-Type` header collides with a multipart body. Used to prove
  # the transport turns an adapter raise into a classified failure instead of letting
  # it crash the batch.
  defmodule RaisingAdapter do
    def deliver(_email, _config) do
      raise KeyError, key: :content_type_params, term: %{}
    end
  end

  # An adapter whose `deliver/2` exits (a gen_smtp GenServer timeout is an exit, not
  # a raise) — the `catch` arm must classify it too.
  defmodule ExitingAdapter do
    def deliver(_email, _config), do: exit(:timeout)
  end

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

    test "drops MIME-structural headers so a stray content-type can't reach the encoder" do
      delivery = %{
        "to" => ["a@x.com"],
        "subject" => "Hi",
        "text" => "hi",
        "headers" => %{
          # Case-insensitive: an upper/mixed-case structural header is still dropped.
          "Content-Type" => "application/json",
          "content-transfer-encoding" => "base64",
          "MIME-Version" => "1.0",
          "Content-Disposition" => "inline",
          "x-event-id" => "evt_1"
        }
      }

      assert {:ok, email} = Email.build_email(connection(), event(delivery))

      # The wire-metadata header survives; the structural ones are gone (Swoosh
      # stores header names as given, so check case-insensitively).
      assert email.headers["x-event-id"] == "evt_1"

      refute Enum.any?(email.headers, fn {name, _} ->
               String.downcase(name) in ~w(content-type content-transfer-encoding mime-version content-disposition)
             end)
    end
  end

  # Regression for the multipart-crash bug: a delivery descriptor carrying
  # `content-type: application/json` (as the old resolver seeded) alongside BOTH an
  # html and a text body used to crash gen_smtp's `mimemail` — it only generates the
  # `multipart/alternative` boundary when no `Content-Type` header is present, so the
  # injected header left the params map empty and `encode_component/5` raised
  # `KeyError key :content_type_params`. Building the email and encoding it must now
  # succeed.
  describe "golden multipart encode (html + text)" do
    test "encodes cleanly even when the descriptor headers include content-type: application/json" do
      delivery = %{
        "to" => ["a@x.com"],
        "subject" => "Order shipped",
        "html" => "<b>shipped</b>",
        "text" => "shipped",
        "headers" => %{"content-type" => "application/json", "x-event-id" => "evt_1"}
      }

      assert {:ok, email} = Email.build_email(connection(), event(delivery))

      # gen_smtp encodes without raising, and the encoded message really is a
      # multipart/alternative carrying both bodies.
      encoded = Swoosh.Adapters.SMTP.Helpers.body(email, [])
      assert is_binary(encoded)
      assert encoded =~ "multipart/alternative"
      assert encoded =~ "shipped"
    end
  end

  # An adapter that RAISES (or exits) must not escape the transport's
  # `{:ok, _} | {:error, classified}` contract — otherwise it crashes the Broadway
  # batch and the delivery silently retries forever with no DeliveryLog written.
  describe "send_email/3 turns an adapter raise into a classified failure" do
    test "a raising adapter becomes a retryable :transport error" do
      {:ok, email} =
        Email.build_email(connection(), event(%{"to" => ["a@x.com"], "text" => "hi"}))

      assert {:error, %{failure_class: :transport, retryable: true, error_message: msg}} =
               Email.send_email(RaisingAdapter, email, [])

      assert msg =~ "SMTP delivery raised"
    end

    test "an exiting adapter becomes a retryable :transport error" do
      {:ok, email} =
        Email.build_email(connection(), event(%{"to" => ["a@x.com"], "text" => "hi"}))

      assert {:error, %{failure_class: :transport, retryable: true, error_message: msg}} =
               Email.send_email(ExitingAdapter, email, [])

      assert msg =~ "SMTP delivery"
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

    test "a :no_more_hosts wrapping a permanent_failure is a non-retryable response, not retryable transport" do
      # gen_smtp returns a hard 5xx rejection as
      # `{:error, :no_more_hosts, {:permanent_failure, host, msg}}`; Swoosh's SMTP
      # adapter re-wraps it as `{:error, {:no_more_hosts, {:permanent_failure, …}}}`.
      # The `:no_more_hosts` reason must be unwrapped to reach the permanent-failure
      # classification (response, non-retryable) rather than being blanket-treated as
      # a retryable connection error — otherwise a 550 is retried forever and
      # suspends the connection instead of the subscription.
      assert %{failure_class: :response, retryable: false, error_message: msg} =
               Email.classify_error(
                 {:no_more_hosts, {:permanent_failure, "mx.acme.com", "550 no such user"}}
               )

      assert msg =~ "550 no such user"
    end

    test "a :no_more_hosts wrapping an auth failure is a non-retryable response" do
      # Auth rejection arrives as `{:permanent_failure, host, :auth_failed}` nested
      # under `:no_more_hosts` (see gen_smtp_client.erl) — a broken credential the
      # relay rejected, non-retryable.
      assert %{failure_class: :response, retryable: false, error_message: msg} =
               Email.classify_error(
                 {:no_more_hosts, {:permanent_failure, "mx.acme.com", :auth_failed}}
               )

      assert msg =~ "auth_failed"
    end

    test "a :no_more_hosts wrapping a temporary_failure is a retryable response" do
      assert %{failure_class: :response, retryable: true} =
               Email.classify_error(
                 {:no_more_hosts, {:temporary_failure, "mx.acme.com", "451 greylisted"}}
               )
    end

    test "a :send wrapping a permanent_failure is a non-retryable response (the common RCPT/DATA 5xx path)" do
      # A bad recipient / rejected content fails during MAIL FROM / RCPT TO / DATA,
      # so gen_smtp returns it as `{:error, :send, {:permanent_failure, host, msg}}`
      # (Swoosh re-wraps → `{:send, {:permanent_failure, …}}`) — the `:send` tag, NOT
      # `:no_more_hosts` (which is connection-setup only). It must be unwrapped too,
      # or the most common permanent rejection stays retryable transport.
      assert %{failure_class: :response, retryable: false, error_message: msg} =
               Email.classify_error(
                 {:send, {:permanent_failure, "mx.acme.com", "550 no such user"}}
               )

      assert msg =~ "550 no such user"
    end

    test "a :send wrapping a temporary_failure is a retryable response" do
      assert %{failure_class: :response, retryable: true} =
               Email.classify_error(
                 {:send, {:temporary_failure, "mx.acme.com", "451 greylisted"}}
               )
    end

    test "a :send wrapping a non-failure inner reason still classifies as retryable transport" do
      # Guards the fall-through direction: an unrecognized inner reason under `:send`
      # unwraps and lands on the retryable-transport catch-all, not a response error.
      assert %{failure_class: :transport, retryable: true} =
               Email.classify_error({:send, :timeout})
    end

    test "a connection-level failure suspends the connection (transport, retryable)" do
      assert %{failure_class: :transport, retryable: true} =
               Email.classify_error(:timeout)

      # A genuine no-hosts condition (DNS/MX resolution failed, no permanent-failure
      # inner reason) still classifies as retryable transport after unwrapping.
      assert %{failure_class: :transport, retryable: true} =
               Email.classify_error({:no_more_hosts, :nxdomain})
    end

    test "an auth/credential failure is a non-retryable transport error" do
      assert %{failure_class: :transport, retryable: false} =
               Email.classify_error(:no_credentials)
    end
  end

  # Microsoft Graph (Swoosh.Adapters.MsGraph) surfaces an API rejection as
  # `{:error, {status, body}}`, a shape none of the gen_smtp clauses match — so
  # before this every Graph error hit the catch-all and became a retryable
  # `:transport` error (a 400 bad recipient or a revoked 401 credential retried
  # forever). Classify on the HTTP status instead.
  describe "classify_error/1 → Microsoft Graph {status, body}" do
    test "a 401/403 is a non-retryable transport error (broken credential, suspend connection)" do
      for status <- [401, 403] do
        assert %{failure_class: :transport, retryable: false} =
                 Email.classify_error({status, %{"error" => %{"message" => "revoked"}}})
      end
    end

    test "a 400 bad-recipient is a non-retryable response (suspend subscription)" do
      assert %{failure_class: :response, retryable: false, error_message: msg} =
               Email.classify_error({400, "Invalid base64 string for MIME content."})

      assert msg =~ "Microsoft Graph rejected (HTTP 400)"
      assert msg =~ "Invalid base64 string"
    end

    test "a structured error body surfaces the error.message detail" do
      assert %{failure_class: :response, error_message: msg} =
               Email.classify_error(
                 {400, %{"error" => %{"code" => "ErrorInvalidRecipients", "message" => "bad to"}}}
               )

      assert msg =~ "bad to"
    end

    test "a 429 / 5xx is a retryable transport error" do
      for status <- [429, 500, 503] do
        assert %{failure_class: :transport, retryable: true} =
                 Email.classify_error({status, %{}})
      end
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

    test "verify_peer defaults server_name_indication to the relay host (STARTTLS SNI)" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(adapter_union(relay: "smtp.gmail.com"), nil)

      tls_options = Keyword.fetch!(config, :tls_options)
      assert Keyword.get(tls_options, :server_name_indication) == ~c"smtp.gmail.com"
    end

    test "an explicit sni overrides the relay host" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(
                 adapter_union(relay: "smtp.internal", sni: "mail.example.com"),
                 nil
               )

      tls_options = Keyword.fetch!(config, :tls_options)
      assert Keyword.get(tls_options, :server_name_indication) == ~c"mail.example.com"
    end

    test "verify_none yields only the chosen opt-out when explicitly selected" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(adapter_union(verify: :verify_none), nil)

      assert Keyword.fetch!(config, :tls_options) == [verify: :verify_none]
    end

    test "verify_none omits server_name_indication even with a relay host" do
      assert {:ok, _adapter, config} =
               Email.adapter_config(
                 adapter_union(verify: :verify_none, relay: "smtp.gmail.com"),
                 nil
               )

      refute Keyword.has_key?(Keyword.fetch!(config, :tls_options), :server_name_indication)
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
