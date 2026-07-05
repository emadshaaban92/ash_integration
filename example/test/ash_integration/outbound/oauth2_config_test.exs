defmodule Example.Outbound.OAuth2ConfigTest do
  @moduledoc """
  The shared OAuth2 client-credentials `client_secret` is encrypted at rest
  (AshCloak) exactly like the HTTP bearer token / SMTP password — for both the HTTP
  `oauth2_client_credentials` auth variant and the Email MsGraph adapter (which
  embeds the same OAuth2 resource). The plaintext never lands in the stored column;
  the transport decrypts it live via `Utils.load_secret/3`. This also covers the
  MsGraph `adapter_config` wiring: it fetches a token and exposes it through
  Swoosh's `auth` fn seam.
  """
  use Example.DataCase, async: false

  alias AshIntegration.Outbound.Wire.Transports.Email
  alias AshIntegration.Transport.OAuth2.TokenCache
  alias AshIntegration.Transport.Utils
  alias Example.Outbound.Connection

  @token_stub AshIntegration.Transport.OAuth2

  setup do
    TokenCache.flush()
    on_exit(&TokenCache.flush/0)
    %{owner: create_user!()}
  end

  describe "HTTP oauth2 client-credentials" do
    test "the client_secret is stored encrypted and decrypts live", %{owner: owner} do
      conn = http_oauth2_connection!(owner, client_secret: "topsecret")

      %Ash.Union{type: :http, value: config} = conn.transport_config
      %Ash.Union{type: :oauth2_client_credentials, value: oauth2} = config.auth

      assert oauth2.encrypted_client_secret != nil
      refute Map.get(oauth2, :client_secret) == "topsecret"

      assert {:ok, loaded} = Utils.load_secret(oauth2, [:client_secret], "OAuth2 client secret")
      assert loaded.client_secret == "topsecret"

      # Non-secret config round-trips.
      assert oauth2.token_url == "https://login.test/oauth2/token"
      assert oauth2.client_id == "cid"
      assert oauth2.scopes == "api.read"
      assert oauth2.auth_style == :post
    end

    test "the client_secret is required", %{owner: owner} do
      assert {:error, _} =
               Connection
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "no-secret-#{System.unique_integer([:positive])}",
                   owner_id: owner.id,
                   transport_config: %{
                     type: :http,
                     base_url: "https://api.example.com",
                     auth: %{
                       type: "oauth2_client_credentials",
                       token_url: "https://login.test/oauth2/token",
                       client_id: "cid"
                     }
                   }
                 },
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "Email MsGraph adapter" do
    test "the client_secret is stored encrypted and decrypts live", %{owner: owner} do
      conn = ms_graph_connection!(owner, client_secret: "graphsecret")

      %Ash.Union{type: :email, value: config} = conn.transport_config
      %Ash.Union{type: :ms_graph, value: ms_graph} = config.adapter

      assert ms_graph.oauth2.encrypted_client_secret != nil
      refute Map.get(ms_graph.oauth2, :client_secret) == "graphsecret"

      assert {:ok, loaded} =
               Utils.load_secret(ms_graph.oauth2, [:client_secret], "OAuth2 client secret")

      assert loaded.client_secret == "graphsecret"
    end

    test "adapter_config builds a MsGraph config whose auth fn returns the token", %{owner: owner} do
      Req.Test.stub(@token_stub, fn conn ->
        Req.Test.json(conn, %{"access_token" => "graph-tok", "expires_in" => 3600})
      end)

      conn = ms_graph_connection!(owner, client_secret: "graphsecret")
      %Ash.Union{type: :email, value: config} = conn.transport_config

      assert {:ok, Swoosh.Adapters.MsGraph, cfg} = Email.adapter_config(config.adapter)
      assert is_function(cfg[:auth], 0)
      assert cfg[:auth].() == "graph-tok"
    end

    test "a user_id pins the sending mailbox via the adapter :url override", %{owner: owner} do
      Req.Test.stub(@token_stub, fn conn ->
        Req.Test.json(conn, %{"access_token" => "graph-tok", "expires_in" => 3600})
      end)

      conn = ms_graph_connection!(owner, client_secret: "s", user_id: "shared@acme.com")
      %Ash.Union{type: :email, value: config} = conn.transport_config

      assert {:ok, Swoosh.Adapters.MsGraph, cfg} = Email.adapter_config(config.adapter)
      assert cfg[:url] == "https://graph.microsoft.com/v1.0/users/shared@acme.com/sendMail"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp http_oauth2_connection!(owner, opts) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "http-oauth2-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "https://api.example.com",
          auth: %{
            type: "oauth2_client_credentials",
            token_url: "https://login.test/oauth2/token",
            client_id: "cid",
            client_secret: opts[:client_secret],
            scopes: "api.read"
          }
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp ms_graph_connection!(owner, opts) do
    oauth2 =
      %{
        token_url: "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
        client_id: "cid",
        client_secret: opts[:client_secret],
        scopes: "https://graph.microsoft.com/.default"
      }

    adapter =
      %{type: "ms_graph", oauth2: oauth2}
      |> maybe_put(:user_id, opts[:user_id])

    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "ms-graph-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{type: :email, from: "bot@acme.com", adapter: adapter}
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "o2-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end
end
