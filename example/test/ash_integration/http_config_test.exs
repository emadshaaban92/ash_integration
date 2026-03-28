defmodule Example.AshIntegration.HttpConfigTest do
  use Example.DataCase
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers

  describe "custom headers" do
    test "custom headers are included in the HTTP request" do
      stub_webhook_capture(self())

      create_outbound_integration!(%{
        transport_config: %{
          url: "http://localhost:9999/webhook",
          auth: %{type: "none"},
          timeout_ms: 5000,
          headers: %{"x-custom-header" => "custom-value", "x-source" => "test"}
        }
      })

      product = create_product!()
      execute_pipeline!(product)

      assert_receive {:webhook_request, request}

      headers_map = Map.new(request.headers)
      assert headers_map["x-custom-header"] == "custom-value"
      assert headers_map["x-source"] == "test"
      assert headers_map["content-type"] == "application/json"
    end
  end

  describe "HTTP method" do
    for method <- [:put, :patch, :delete] do
      test "uses #{method} when configured" do
        stub_webhook_capture(self())

        create_outbound_integration!(%{
          transport_config: %{
            url: "http://localhost:9999/webhook",
            auth: %{type: "none"},
            timeout_ms: 5000,
            method: unquote(method)
          }
        })

        product = create_product!()
        execute_pipeline!(product)

        assert_receive {:webhook_request, request}
        assert request.method == String.upcase(to_string(unquote(method)))
      end
    end
  end

  describe "URL validation" do
    test "rejects non-HTTP URLs" do
      assert {:error, _} =
               Example.Integration.OutboundIntegration
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "bad-url-integration",
                   resource: "product",
                   actions: ["create"],
                   schema_version: 1,
                   transport_config: %{
                     url: "ftp://example.com/webhook",
                     auth: %{type: "none"}
                   },
                   transform_script: "result = event",
                   owner_id: create_user!().id
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "auth modes" do
    test "bearer token auth sends Authorization header" do
      stub_webhook_capture(self())

      create_outbound_integration!(%{
        transport_config: %{
          url: "http://localhost:9999/webhook",
          auth: %{type: "bearer_token", token: "my-secret-token"},
          timeout_ms: 5000
        }
      })

      product = create_product!()
      execute_pipeline!(product)

      assert_receive {:webhook_request, request}

      auth_header =
        request.headers
        |> Enum.find_value(fn {k, v} -> if k == "authorization", do: v end)

      assert auth_header == "Bearer my-secret-token"
    end

    test "basic auth sends encoded Authorization header" do
      stub_webhook_capture(self())

      create_outbound_integration!(%{
        transport_config: %{
          url: "http://localhost:9999/webhook",
          auth: %{type: "basic_auth", username: "user", password: "pass"},
          timeout_ms: 5000
        }
      })

      product = create_product!()
      execute_pipeline!(product)

      assert_receive {:webhook_request, request}

      auth_header =
        request.headers
        |> Enum.find_value(fn {k, v} -> if k == "authorization", do: v end)

      expected = "Basic " <> Base.encode64("user:pass")
      assert auth_header == expected
    end

    test "API key auth sends custom header" do
      stub_webhook_capture(self())

      create_outbound_integration!(%{
        transport_config: %{
          url: "http://localhost:9999/webhook",
          auth: %{type: "api_key", header_name: "x-api-key", value: "secret-key-123"},
          timeout_ms: 5000
        }
      })

      product = create_product!()
      execute_pipeline!(product)

      assert_receive {:webhook_request, request}

      api_key_header =
        request.headers
        |> Enum.find_value(fn {k, v} -> if k == "x-api-key", do: v end)

      assert api_key_header == "secret-key-123"
    end
  end
end
