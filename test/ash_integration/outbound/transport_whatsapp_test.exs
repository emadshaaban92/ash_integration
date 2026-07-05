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

  describe "classify_error/1 → two-level suspension mapping" do
    defp error(code), do: %{"error" => %{"code" => code, "message" => "boom"}}

    test "rate / pair-rate limits are retryable transport errors" do
      for code <- [429, 130_429, 80_007, 131_056] do
        assert %{failure_class: :transport, retryable: true} =
                 WhatsApp.classify_error(error(code))
      end
    end

    test "an expired/invalid access token is a non-retryable transport error (suspend connection)" do
      assert %{failure_class: :transport, retryable: false, error_message: msg} =
               WhatsApp.classify_error(error(190))

      assert msg =~ "190"
    end

    test "a policy block (368) is a non-retryable transport error" do
      assert %{failure_class: :transport, retryable: false} = WhatsApp.classify_error(error(368))
    end

    test "undeliverable / re-engagement / unsupported / invalid-param are response failures" do
      for code <- [131_026, 131_047, 131_051, 100] do
        assert %{failure_class: :response, retryable: false} =
                 WhatsApp.classify_error(error(code))
      end
    end

    test "template errors across the 132000–132016 band are non-retryable response failures" do
      for code <- [132_000, 132_001, 132_007, 132_012, 132_016] do
        assert %{failure_class: :response, retryable: false} =
                 WhatsApp.classify_error(error(code))
      end
    end

    test "an unknown code defaults to a retryable transport error (mirrors HTTP's network default)" do
      assert %{failure_class: :transport, retryable: true} =
               WhatsApp.classify_error(error(999_999))
    end

    test "a bodyless / unparsable error still classifies rather than crashing" do
      assert %{failure_class: :transport, retryable: true} = WhatsApp.classify_error(nil)
      assert %{failure_class: :transport, retryable: true} = WhatsApp.classify_error("not json")
      assert %{failure_class: :transport, retryable: true} = WhatsApp.classify_error(%{})
    end

    test "a raw JSON string body is decoded before classification" do
      body = ~s({"error":{"code":190,"message":"Session expired"}})

      assert %{failure_class: :transport, retryable: false, error_message: msg} =
               WhatsApp.classify_error(body)

      assert msg =~ "Session expired"
    end
  end
end
