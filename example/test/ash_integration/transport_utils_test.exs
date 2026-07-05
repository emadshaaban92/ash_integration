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
    # Regression guard: every transport routes its credential/secret
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

  describe "partition_for/2 (Kafka murmur2)" do
    # Vectors from Kafka's reference partitioner (org.apache.kafka...DefaultPartitioner),
    # cross-checked against kafka-python's Java-compatibility suite:
    # toPositive(murmur2(key)) % 1000.
    test "matches Kafka's murmur2 partitioner over 1000 partitions" do
      assert Utils.partition_for("", 1000) == 681
      assert Utils.partition_for("a", 1000) == 524
      assert Utils.partition_for("ab", 1000) == 434
      assert Utils.partition_for("abc", 1000) == 107
      assert Utils.partition_for("123456789", 1000) == 566
    end

    test "a single-partition topic always returns 0" do
      assert Utils.partition_for("anything", 1) == 0
    end

    test "is deterministic and in-range" do
      for key <- ["k1", "order-42", "widget-999"] do
        p = Utils.partition_for(key, 12)
        assert p == Utils.partition_for(key, 12)
        assert p in 0..11
      end
    end
  end

  describe "retryable_error?/1 (Kafka/brod produce errors)" do
    test "transient broker/metadata errors are retryable" do
      for reason <- [
            :leader_not_available,
            :not_leader_for_partition,
            :request_timed_out,
            :coordinator_not_available,
            {:connect_error, :nxdomain}
          ] do
        assert Utils.retryable_error?(reason), "expected #{inspect(reason)} to be retryable"
      end
    end

    test "brod lifecycle races (client_down / producer_down) are retryable, not terminal" do
      # These are benign transient races — the client restarting, or idle cleanup
      # terminating a partition producer that raced an in-flight produce — not real
      # broker rejections. The supervisor brings the process back, so retry rather
      # than permanently failing the delivery.
      assert Utils.retryable_error?(:client_down)
      assert Utils.retryable_error?({:client_down, :shutdown})
      assert Utils.retryable_error?({:producer_down, :normal})
    end

    test "an unknown error stays non-retryable (surface permanent failures quickly)" do
      refute Utils.retryable_error?(:unknown_server_error)
      refute Utils.retryable_error?(:message_too_large)
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

  describe "mask_response_body/1" do
    test "masks reflected auth/signature/cookie headers echoed in the body" do
      body =
        ~s({"authorization":"Bearer s3cret","x-signature":"t=1,v1=abc","cookie":"sid=xyz","ok":true})

      masked = Utils.mask_response_body(body)

      refute masked =~ "s3cret"
      refute masked =~ "v1=abc"
      refute masked =~ "sid=xyz"
      assert masked =~ "[REDACTED]"
      # The OTHER system's actual content is preserved.
      assert masked =~ "ok"
    end

    test "is idempotent — masking an already-masked body is a no-op" do
      body = ~s({"authorization":"Bearer s3cret","ok":true})
      once = Utils.mask_response_body(body)

      assert Utils.mask_response_body(once) == once
      refute once =~ "s3cret"
    end

    test "does NOT truncate — a long non-secret body passes through whole" do
      body = String.duplicate("x", 10_000)
      assert Utils.mask_response_body(body) == body
    end

    test "passes nil through" do
      assert Utils.mask_response_body(nil) == nil
    end
  end

  describe "mask_and_cap_response_body/1" do
    test "masks a reflected secret in the stored copy" do
      body = ~s(reflected request headers: authorization: Bearer s3cret-token)
      result = Utils.mask_and_cap_response_body(body)

      refute result =~ "s3cret-token"
      assert result =~ "[REDACTED]"
    end

    test "keeps a normal body full-size but caps a pathological body over the default ceiling" do
      # Under the generous default ceiling: verbatim, no truncation.
      small = String.duplicate("y", 10_000)
      assert Utils.mask_and_cap_response_body(small) == small

      # Over the default 64 KB ceiling: capped, but far more generously than the
      # 4 KB audit Log copy (`redact_response_body/1`).
      huge = String.duplicate("z", 70_000)
      stored = Utils.mask_and_cap_response_body(huge)

      assert stored =~ "(truncated)"
      assert byte_size(stored) < byte_size(huge)
      assert byte_size(stored) > 4_096
      assert byte_size(Utils.redact_response_body(huge)) < byte_size(stored)
    end

    test "reads the ceiling from config (:max_stored_response_body_len)" do
      original = Application.get_env(:ash_integration, :max_stored_response_body_len)
      Application.put_env(:ash_integration, :max_stored_response_body_len, 128)

      try do
        stored = Utils.mask_and_cap_response_body(String.duplicate("z", 500))

        assert stored =~ "(truncated)"
        assert byte_size(stored) < 500
      after
        case original do
          nil -> Application.delete_env(:ash_integration, :max_stored_response_body_len)
          value -> Application.put_env(:ash_integration, :max_stored_response_body_len, value)
        end
      end
    end

    test "passes nil through" do
      assert Utils.mask_and_cap_response_body(nil) == nil
    end
  end
end
