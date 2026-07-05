defmodule Example.Outbound.TransportWhatsAppTest do
  @moduledoc """
  End-to-end tests for the WhatsApp transport against a stubbed Meta Cloud API
  (`Req.Test`). These drive `WhatsApp.deliver/2` directly so they can assert the
  full live path — decrypt the access token, POST the shaped Graph JSON to
  `graph.facebook.com`, and classify the response for two-level suspension — and
  the returned success/error metadata (the `wamid`, the failure class/retryable).
  The connection is DB-backed so the AshCloak decrypt is real.
  """
  use Example.DataCase, async: false

  alias AshIntegration.Outbound.Wire.Transports.WhatsApp
  alias Example.Outbound.Connection

  @stub AshIntegration.Outbound.Wire.Transports.WhatsApp

  setup do
    %{connection: whatsapp_connection!(create_user!(), access_token: "EAAG-live-token")}
  end

  test "posts the shaped template payload with the Bearer token to the versioned graph endpoint",
       %{connection: connection} do
    parent = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:graph_request,
         %{
           method: conn.method,
           host: conn.host,
           path: conn.request_path,
           headers: conn.req_headers,
           body: body
         }}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "messaging_product" => "whatsapp",
          "contacts" => [%{"input" => "15551234567", "wa_id" => "15551234567"}],
          "messages" => [%{"id" => "wamid.HBgLABCDEF"}]
        })
      )
    end)

    event = event(template_descriptor())

    assert {:ok, meta} = WhatsApp.deliver(connection, event)
    assert meta.whatsapp_message_id == "wamid.HBgLABCDEF"
    assert meta.response_status == 200

    assert_received {:graph_request, req}
    assert req.method == "POST"
    assert req.host == "graph.facebook.com"
    assert req.path == "/v21.0/123456789012345/messages"

    headers = Map.new(req.headers, fn {k, v} -> {String.downcase(k), v} end)
    assert headers["authorization"] == "Bearer EAAG-live-token"
    assert headers["content-type"] =~ "application/json"

    assert Jason.decode!(req.body) == %{
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
                     %{"type" => "text", "text" => "A-1"}
                   ]
                 }
               ]
             }
           }
  end

  test "posts a text (session) message body", %{connection: connection} do
    parent = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:graph_body, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"messages" => [%{"id" => "wamid.T"}]}))
    end)

    descriptor = %{"to" => "15551234567", "type" => "text", "text" => "hello"}

    assert {:ok, %{whatsapp_message_id: "wamid.T"}} =
             WhatsApp.deliver(connection, event(descriptor))

    assert_received {:graph_body, body}

    assert Jason.decode!(body) == %{
             "messaging_product" => "whatsapp",
             "recipient_type" => "individual",
             "to" => "15551234567",
             "type" => "text",
             "text" => %{"preview_url" => false, "body" => "hello"}
           }
  end

  test "a 4xx template error is a non-retryable :response failure (suspend subscription)", %{
    connection: connection
  } do
    stub_graph_error(400, %{"error" => %{"code" => 132_001, "message" => "template not found"}})

    assert {:error, error} = WhatsApp.deliver(connection, event(template_descriptor()))
    assert error.failure_class == :response
    assert error.retryable == false
  end

  test "a 429 rate limit is a RETRYABLE :transport failure honoring Retry-After", %{
    connection: connection
  } do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_resp_header("retry-after", "120")
      |> Plug.Conn.send_resp(
        429,
        Jason.encode!(%{"error" => %{"code" => 130_429, "message" => "rate limited"}})
      )
    end)

    assert {:error, error} = WhatsApp.deliver(connection, event(template_descriptor()))
    assert error.failure_class == :transport
    assert error.retryable == true
    assert error.retry_after_ms == 120_000
  end

  test "an expired access token (code 190) is a non-retryable :transport failure", %{
    connection: connection
  } do
    stub_graph_error(401, %{"error" => %{"code" => 190, "message" => "session expired"}})

    assert {:error, error} = WhatsApp.deliver(connection, event(template_descriptor()))
    assert error.failure_class == :transport
    assert error.retryable == false
  end

  test "a 5xx with no recognized code is a retryable :transport failure", %{
    connection: connection
  } do
    stub_graph_error(500, %{"error" => %{"message" => "internal"}})

    assert {:error, error} = WhatsApp.deliver(connection, event(template_descriptor()))
    assert error.failure_class == :transport
    assert error.retryable == true
  end

  test "a connection-level error is a retryable :transport failure", %{connection: connection} do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, error} = WhatsApp.deliver(connection, event(template_descriptor()))
    assert error.failure_class == :transport
    assert error.retryable == true
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp stub_graph_error(status, body) do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp event(delivery), do: %{delivery: delivery}

  defp template_descriptor do
    %{
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
              %{"type" => "text", "text" => "A-1"}
            ]
          }
        ]
      }
    }
  end

  defp whatsapp_connection!(owner, opts) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "wa-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :whatsapp,
          adapter: %{
            type: "meta_cloud",
            phone_number_id: "123456789012345",
            api_version: "v21.0",
            access_token: opts[:access_token]
          }
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "wa-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end
end
