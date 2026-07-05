defmodule Example.Outbound.ConnectionFormLiveTest do
  @moduledoc """
  LiveView coverage for the connection edit form's transport-specific subforms.

  Regression: mounting the edit form for a Kafka connection used to crash with
  `AshPhoenix.Form.NoFormConfigured: auth` because `init_form/1`'s `:edit` clause
  unconditionally ensured the HTTP-only `auth` subform. The `:edit` path must
  branch on the connection's transport like the transport-type-changed handler:
  `auth` for HTTP, `security` for Kafka, and `signing` for both.
  """
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Example.Outbound.Connection

  setup %{conn: conn} do
    user = create_user!()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    %{conn: conn, user: user}
  end

  test "mounts the edit form for a Kafka connection with its security subform", %{
    conn: conn,
    user: user
  } do
    kafka = create_kafka_connection!(user)

    {:ok, _view, html} = live(conn, edit_path(kafka.id))

    # The Kafka connection gets the security subform, not the HTTP-only auth one.
    assert html =~ ~s(name="form[transport_config][security][_union_type]")
    refute html =~ ~s(name="form[transport_config][auth][_union_type]")
    # Signing applies to every transport.
    assert html =~ ~s(name="form[transport_config][signing][_union_type]")
  end

  test "mounts the edit form for an HTTP connection with its auth subform", %{
    conn: conn,
    user: user
  } do
    http = create_http_connection!(user)

    {:ok, _view, html} = live(conn, edit_path(http.id))

    assert html =~ ~s(name="form[transport_config][auth][_union_type]")
    refute html =~ ~s(name="form[transport_config][security][_union_type]")
    assert html =~ ~s(name="form[transport_config][signing][_union_type]")
  end

  test "mounts the edit form for an Email connection with its SMTP adapter subform", %{
    conn: conn,
    user: user
  } do
    email = create_email_connection!(user)

    {:ok, _view, html} = live(conn, edit_path(email.id))

    # Email gets the adapter subform, not auth/security.
    assert html =~ ~s(name="form[transport_config][adapter][_union_type]")
    refute html =~ ~s(name="form[transport_config][auth][_union_type]")
    refute html =~ ~s(name="form[transport_config][security][_union_type]")
    # Email has no payload-signing scheme, so that card is not rendered.
    refute html =~ ~s(name="form[transport_config][signing][_union_type]")
  end

  test "mounts the edit form for an HTTP OAuth2 connection with its client-credentials fields",
       %{conn: conn, user: user} do
    http = create_http_oauth2_connection!(user)

    {:ok, _view, html} = live(conn, edit_path(http.id))

    assert html =~ ~s(name="form[transport_config][auth][_union_type]")
    # The OAuth2 client-credentials fields render for the stored variant.
    assert html =~ ~s(name="form[transport_config][auth][token_url]")
    assert html =~ ~s(name="form[transport_config][auth][client_id]")
    assert html =~ ~s(name="form[transport_config][auth][client_secret]")
  end

  test "mounts the edit form for an Email MsGraph connection with its nested OAuth2 subform",
       %{conn: conn, user: user} do
    email = create_ms_graph_connection!(user)

    {:ok, _view, html} = live(conn, edit_path(email.id))

    assert html =~ ~s(name="form[transport_config][adapter][_union_type]")
    # The shared OAuth2 resource renders nested under the MsGraph adapter.
    assert html =~ ~s(name="form[transport_config][adapter][oauth2][token_url]")
    assert html =~ ~s(name="form[transport_config][adapter][oauth2][client_secret]")
  end

  test "switching the email adapter to MsGraph reveals the nested OAuth2 subform", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/integrations/connections/new")

    # Select the Email transport, then the MsGraph adapter — the second switch is
    # the path that adds the nested OAuth2 subform to a fresh (data-less) form.
    view
    |> element("select[name=transport_selector]")
    |> render_change(%{"transport_selector" => "email"})

    html =
      view
      |> element("select[name='form[transport_config][adapter][_union_type]']")
      |> render_change(%{
        "_target" => ["form", "transport_config", "adapter", "_union_type"],
        "form" => %{"transport_config" => %{"adapter" => %{"_union_type" => "ms_graph"}}}
      })

    assert html =~ ~s(name="form[transport_config][adapter][oauth2][token_url]")
    assert html =~ ~s(name="form[transport_config][adapter][oauth2][client_secret]")
  end

  test "mounts the edit form for a WhatsApp connection with its Meta Cloud adapter subform", %{
    conn: conn,
    user: user
  } do
    whatsapp = create_whatsapp_connection!(user)

    {:ok, _view, html} = live(conn, edit_path(whatsapp.id))

    # WhatsApp gets the adapter subform, not auth/security.
    assert html =~ ~s(name="form[transport_config][adapter][_union_type]")
    refute html =~ ~s(name="form[transport_config][auth][_union_type]")
    refute html =~ ~s(name="form[transport_config][security][_union_type]")
    # WhatsApp has no payload-signing scheme, so that card is not rendered.
    refute html =~ ~s(name="form[transport_config][signing][_union_type]")
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp edit_path(id), do: "/integrations/connections/edit/#{id}"

  defp create_http_oauth2_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "HTTP-OAuth2-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "https://api.example.com",
          auth: %{
            type: "oauth2_client_credentials",
            token_url: "https://login.test/oauth2/token",
            client_id: "cid",
            client_secret: "shh",
            scopes: "api.read"
          },
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_ms_graph_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Email-Graph-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :email,
          from: "notifications@acme.com",
          adapter: %{
            type: "ms_graph",
            oauth2: %{
              token_url: "https://login.microsoftonline.com/t/oauth2/v2.0/token",
              client_id: "cid",
              client_secret: "shh",
              scopes: "https://graph.microsoft.com/.default"
            }
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
      %{email: "conn-form-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end

  defp create_http_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "HTTP-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "https://api.example.com",
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_kafka_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Kafka-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :kafka,
          brokers: ["localhost:9092"],
          topic: "default-topic",
          security: %{type: "none"}
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_email_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Email-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :email,
          from: "notifications@acme.com",
          adapter: %{type: "smtp", relay: "smtp.acme.com", port: 587}
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_whatsapp_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "WhatsApp-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :whatsapp,
          adapter: %{
            type: "meta_cloud",
            phone_number_id: "123456789012345",
            api_version: "v21.0",
            access_token: "EAAG-token"
          }
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
