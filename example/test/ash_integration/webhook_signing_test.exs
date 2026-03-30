defmodule Example.AshIntegration.WebhookSigningTest do
  use Example.DataCase
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers

  describe "HMAC signing" do
    test "signed request includes x-webhook-signature header with valid HMAC" do
      secret = "test-signing-secret-12345"

      stub_webhook_capture(self())

      create_outbound_integration!(%{
        transport_config: %{
          type: :http,
          url: "http://localhost:9999/webhook",
          auth: %{type: "none"},
          timeout_ms: 5000,
          signing_secret: secret
        }
      })

      product = create_product!()
      execute_pipeline!(product)

      assert_receive {:webhook_request, request}

      sig_header =
        request.headers
        |> Enum.find_value(fn {k, v} -> if k == "x-webhook-signature", do: v end)

      assert sig_header != nil, "Expected x-webhook-signature header"

      # Parse t= and v1= from header
      [t_part, v1_part] = String.split(sig_header, ",")
      "t=" <> timestamp = t_part
      "v1=" <> signature = v1_part

      # Verify HMAC matches
      signed_payload = "#{timestamp}.#{request.body}"

      expected_signature =
        :crypto.mac(:hmac, :sha256, secret, signed_payload)
        |> Base.encode16(case: :lower)

      assert signature == expected_signature
    end

    test "unsigned request has no x-webhook-signature header" do
      stub_webhook_capture(self())

      create_outbound_integration!(%{
        transport_config: %{
          type: :http,
          url: "http://localhost:9999/webhook",
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      })

      product = create_product!()
      execute_pipeline!(product)

      assert_receive {:webhook_request, request}

      sig_header =
        request.headers
        |> Enum.find_value(fn {k, v} -> if k == "x-webhook-signature", do: v end)

      assert sig_header == nil, "Expected no x-webhook-signature header"
    end
  end
end
