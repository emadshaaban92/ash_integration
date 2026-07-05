defmodule AshIntegration.Outbound.Wire.Transports.WhatsAppTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Wire.Transports.WhatsApp

  # The descriptor is already normalized/validated by the resolver, so these
  # exercise the pure Graph-JSON shaping (semantic descriptor → Cloud API payload)
  # and the error-code classification — no network needed, mirroring the Email
  # transport's `build_email/2` and the Kafka transport's `build_message/2`.
  describe "build_payload/1 — text (session) message" do
    test "shapes a text body onto the Cloud API request" do
      descriptor = %{"to" => "15551234567", "type" => "text", "text" => "hello there"}

      assert WhatsApp.build_payload(descriptor) == %{
               "messaging_product" => "whatsapp",
               "recipient_type" => "individual",
               "to" => "15551234567",
               "type" => "text",
               "text" => %{"preview_url" => false, "body" => "hello there"}
             }
    end
  end

  describe "build_payload/1 — template message" do
    test "wraps the language code and passes components through" do
      descriptor = %{
        "to" => "15551234567",
        "type" => "template",
        "template" => %{
          "name" => "order_shipped",
          "language" => "en_US",
          "components" => [
            %{
              "type" => "body",
              "parameters" => [
                %{"type" => "text", "text" => "John"},
                %{"type" => "text", "text" => "12345"}
              ]
            }
          ]
        }
      }

      assert WhatsApp.build_payload(descriptor) == %{
               "messaging_product" => "whatsapp",
               "to" => "15551234567",
               "type" => "template",
               "template" => %{
                 "name" => "order_shipped",
                 "language" => %{"code" => "en_US"},
                 "components" => [
                   %{
                     "type" => "body",
                     "parameters" => [
                       %{"type" => "text", "text" => "John"},
                       %{"type" => "text", "text" => "12345"}
                     ]
                   }
                 ]
               }
             }
    end

    test "omits components entirely for a parameter-free template" do
      descriptor = %{
        "to" => "15551234567",
        "type" => "template",
        "template" => %{"name" => "hello_world", "language" => "en_US"}
      }

      payload = WhatsApp.build_payload(descriptor)

      assert payload["template"] == %{"name" => "hello_world", "language" => %{"code" => "en_US"}}
      refute Map.has_key?(payload["template"], "components")
    end
  end

  describe "classify_error/2 → two-level suspension mapping" do
    defp error(code), do: %{"error" => %{"code" => code, "message" => "boom"}}

    test "rate / pair-rate limits are retryable transport errors" do
      for code <- [429, 130_429, 80_007, 131_056] do
        assert %{failure_class: :transport, retryable: true} =
                 WhatsApp.classify_error(error(code), 400)
      end
    end

    test "an expired/invalid access token is a non-retryable transport error (suspend connection)" do
      assert %{failure_class: :transport, retryable: false, error_message: msg} =
               WhatsApp.classify_error(error(190), 401)

      assert msg =~ "190"
    end

    test "a recognized code refines the status baseline (190 on a 500 is still non-retryable)" do
      # The HTTP status alone (500) would retry; the recognized token-failure code
      # overrides it to non-retryable so a broken credential suspends, not loops.
      assert %{failure_class: :transport, retryable: false} =
               WhatsApp.classify_error(error(190), 500)
    end

    test "a policy block (368) is a non-retryable transport error" do
      assert %{failure_class: :transport, retryable: false} =
               WhatsApp.classify_error(error(368), 403)
    end

    test "undeliverable / re-engagement / unsupported / invalid-param are response failures" do
      for code <- [131_026, 131_047, 131_051, 100] do
        assert %{failure_class: :response, retryable: false} =
                 WhatsApp.classify_error(error(code), 400)
      end
    end

    test "template errors across the 132000–132016 band are non-retryable response failures" do
      for code <- [132_000, 132_001, 132_007, 132_012, 132_016] do
        assert %{failure_class: :response, retryable: false} =
                 WhatsApp.classify_error(error(code), 400)
      end
    end

    test "an unmapped code on a deterministic 4xx is NON-retryable (does not burn retries)" do
      # A new/unrecognized code arriving on a 400 is a deterministic rejection, so
      # it defers to the HTTP-status baseline (non-retryable) rather than the old
      # blanket retryable default that looped until the health window suspended.
      assert %{failure_class: :transport, retryable: false} =
               WhatsApp.classify_error(error(999_999), 400)
    end

    test "an unmapped code on a 429 is retryable (status baseline says try again)" do
      assert %{failure_class: :transport, retryable: true} =
               WhatsApp.classify_error(error(999_999), 429)
    end

    test "an unmapped code on a 5xx is retryable (mirrors HTTP's server-error default)" do
      assert %{failure_class: :transport, retryable: true} =
               WhatsApp.classify_error(error(999_999), 503)
    end

    test "a string error.code is coerced so \"190\" isn't treated as unknown" do
      assert %{failure_class: :transport, retryable: false} =
               WhatsApp.classify_error(error("190"), 500)
    end

    test "a bodyless / unparsable error defers to the HTTP status" do
      # No recognized code → the status decides: a 5xx retries, a 4xx does not.
      assert %{failure_class: :transport, retryable: true} = WhatsApp.classify_error(nil, 500)

      assert %{failure_class: :transport, retryable: true} =
               WhatsApp.classify_error("not json", 500)

      assert %{failure_class: :transport, retryable: true} = WhatsApp.classify_error(%{}, 500)
      assert %{failure_class: :transport, retryable: false} = WhatsApp.classify_error(nil, 400)
    end

    test "a raw JSON string body is decoded before classification" do
      body = ~s({"error":{"code":190,"message":"Session expired"}})

      assert %{failure_class: :transport, retryable: false, error_message: msg} =
               WhatsApp.classify_error(body, 401)

      assert msg =~ "Session expired"
    end
  end
end
