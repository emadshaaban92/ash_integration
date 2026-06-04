defmodule AshIntegration.TransportUtilsTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Transport.Utils

  describe "build_url/2" do
    test "returns the base URL unchanged for a nil or empty path" do
      assert Utils.build_url("https://api.example.com", nil) == "https://api.example.com"
      assert Utils.build_url("https://api.example.com", "") == "https://api.example.com"
    end

    test "joins base and path with exactly one slash regardless of surrounding slashes" do
      expected = "https://api.example.com/widgets"

      assert Utils.build_url("https://api.example.com", "/widgets") == expected
      assert Utils.build_url("https://api.example.com", "widgets") == expected
      assert Utils.build_url("https://api.example.com/", "/widgets") == expected
      assert Utils.build_url("https://api.example.com/", "widgets") == expected
    end

    test "preserves a base path on the connection" do
      assert Utils.build_url("https://api.example.com/v1", "/widgets") ==
               "https://api.example.com/v1/widgets"
    end
  end

  describe "load_secret/3" do
    # Regression guard for #76: every transport routes its credential/secret
    # decryption through here so that a decryption/vault failure becomes a
    # classified, NON-retryable :transport error instead of a raised MatchError
    # that escapes the {:error, %{failure_class: ...}} contract (which left the
    # Oban job crashing and retrying forever, never counting toward suspension).
    test "classifies a load that RAISES as a non-retryable transport failure" do
      assert {:error, %{failure_class: :transport, retryable: false} = error} =
               Utils.load_secret(%{not: "an ash record"}, [:token], "bearer token")

      assert error.error_message =~ "Failed to load bearer token"
    end

    test "labels the error with the given secret context" do
      assert {:error, %{error_message: message}} =
               Utils.load_secret(%{not: "an ash record"}, [:password], "Kafka SASL credentials")

      assert message =~ "Failed to load Kafka SASL credentials"
    end
  end

  describe "scrub_reason/1" do
    test "passes through readable network reasons (atoms, tuples)" do
      assert Utils.scrub_reason(:econnrefused) == ":econnrefused"
      assert Utils.scrub_reason({:tls_alert, :handshake_failure}) =~ "tls_alert"
    end

    test "collapses an arbitrary struct to its module name (no field splat)" do
      # A struct that embeds a decrypted credential must never reach last_error.
      reason = %URI{userinfo: "user:s3cret-token", host: "internal"}
      scrubbed = Utils.scrub_reason(reason)

      assert scrubbed == "URI"
      refute scrubbed =~ "s3cret-token"
    end

    test "collapses an exception to its module name" do
      assert Utils.scrub_reason(%RuntimeError{message: "boom token=abc"}) == "RuntimeError"
    end

    test "redacts a tuple carrying a non-simple secret-bearing term" do
      reason = {:error, %{token: "s3cret"}}
      refute Utils.scrub_reason(reason) =~ "s3cret"
    end

    test "truncates an overlong binary reason" do
      assert Utils.scrub_reason(String.duplicate("a", 5_000)) =~ "(truncated)"
    end
  end

  describe "redact_descriptor/1" do
    test "redacts secret-bearing header values, keeps the rest" do
      descriptor = %{
        "url" => "https://api.example.com/hook",
        "headers" => %{
          "authorization" => "Bearer s3cret-token",
          "x-signature" => "t=1,v1=deadbeef",
          "x-event-type" => "widget.updated"
        }
      }

      redacted = Utils.redact_descriptor(descriptor)

      assert redacted["headers"]["authorization"] == "[REDACTED]"
      assert redacted["headers"]["x-signature"] == "[REDACTED]"
      assert redacted["headers"]["x-event-type"] == "widget.updated"
      assert redacted["url"] == "https://api.example.com/hook"
    end

    test "leaves a descriptor without headers untouched" do
      assert Utils.redact_descriptor(%{"url" => "x"}) == %{"url" => "x"}
      assert Utils.redact_descriptor(nil) == nil
    end
  end

  describe "redact_response_body/1" do
    test "masks reflected auth/signature headers echoed in the body" do
      body = ~s({"authorization":"Bearer s3cret","x-signature":"t=1,v1=abc","ok":true})
      masked = Utils.redact_response_body(body)

      refute masked =~ "s3cret"
      refute masked =~ "v1=abc"
      assert masked =~ "[REDACTED]"
      assert masked =~ "ok"
    end

    test "truncates an overlong body" do
      assert Utils.redact_response_body(String.duplicate("x", 10_000)) =~ "(truncated)"
    end

    test "passes nil through" do
      assert Utils.redact_response_body(nil) == nil
    end
  end
end
