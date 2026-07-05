defmodule AshIntegration.Outbound.Wire.Transports.EmailTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Wire.Transports.Email

  # The descriptor is already normalized/validated by the resolver, so these
  # exercise the pure replay mapping (delivery descriptor → Swoosh.Email) and the
  # failure classification — no SMTP server needed, mirroring the Kafka transport's
  # `build_message/2` unit tests.
  defp connection(from \\ "bot@acme.com"),
    do: %{transport_config: %Ash.Union{type: :email, value: %{from: from}}}

  defp event(delivery), do: %{delivery: delivery}

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
end
