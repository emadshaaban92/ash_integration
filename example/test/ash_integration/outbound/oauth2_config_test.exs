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

      assert {:ok, Swoosh.Adapters.MsGraph, cfg} =
               Email.adapter_config(config.adapter, graph_email("bot@acme.com"))

      assert is_function(cfg[:auth], 0)
      assert cfg[:auth].() == "graph-tok"
    end

    test "a user_id pins the sending mailbox via the adapter :url override", %{owner: owner} do
      Req.Test.stub(@token_stub, fn conn ->
        Req.Test.json(conn, %{"access_token" => "graph-tok", "expires_in" => 3600})
      end)

      conn = ms_graph_connection!(owner, client_secret: "s", user_id: "shared@acme.com")
      %Ash.Union{type: :email, value: config} = conn.transport_config

      assert {:ok, Swoosh.Adapters.MsGraph, cfg} =
               Email.adapter_config(config.adapter, graph_email("bot@acme.com"))

      # The mailbox is reserved-safe-encoded (`@` -> `%40`), so no path/query
      # metacharacter in a mailbox could ever survive into the URL.
      assert cfg[:url] == "https://graph.microsoft.com/v1.0/users/shared%40acme.com/sendMail"
    end

    test "without a user_id the :url is pinned from the (encoded) from address",
         %{owner: owner} do
      Req.Test.stub(@token_stub, fn conn ->
        Req.Test.json(conn, %{"access_token" => "graph-tok", "expires_in" => 3600})
      end)

      conn = ms_graph_connection!(owner, client_secret: "s")
      %Ash.Union{type: :email, value: config} = conn.transport_config

      assert {:ok, Swoosh.Adapters.MsGraph, cfg} =
               Email.adapter_config(config.adapter, graph_email("sender@acme.com"))

      # Swoosh is NEVER left to interpolate the raw `from` itself — the transport
      # always pins an explicit, encoded `:url`.
      assert cfg[:url] == "https://graph.microsoft.com/v1.0/users/sender%40acme.com/sendMail"
    end

    test "a path-bearing user_id cannot escape the /users/{id}/sendMail path",
         %{owner: owner} do
      Req.Test.stub(@token_stub, fn conn ->
        Req.Test.json(conn, %{"access_token" => "graph-tok", "expires_in" => 3600})
      end)

      # A user_id like this would rewrite the path AND add a query if interpolated
      # raw. It's rejected at config time; force it past validation to prove the
      # send path (encoding) is a second, independent line of defense.
      conn = ms_graph_connection!(owner, client_secret: "s")
      %Ash.Union{value: config} = conn.transport_config
      %Ash.Union{value: ms_graph} = adapter = config.adapter
      adapter_union = %{adapter | value: %{ms_graph | user_id: "x/../../beta/me?$top=1"}}

      assert {:ok, Swoosh.Adapters.MsGraph, cfg} =
               Email.adapter_config(adapter_union, graph_email("bot@acme.com"))

      %URI{host: host, path: path, query: query} = URI.parse(cfg[:url])
      assert host == "graph.microsoft.com"
      # Exactly three path segments after the host: users / <one mailbox> / sendMail.
      assert ["", "v1.0", "users", _mailbox, "sendMail"] = String.split(path, "/")
      assert query == nil
    end

    test "the SEND request reaches the fixed Graph host + /users/{id}/sendMail path",
         %{owner: owner} do
      test_pid = self()

      Req.Test.stub(@token_stub, fn conn ->
        Req.Test.json(conn, %{"access_token" => "graph-tok", "expires_in" => 3600})
      end)

      # The SEND goes through Swoosh's Req ApiClient, routed to this Req.Test owner
      # by the `:graph_req_options` test config. Capture the request the adapter
      # actually issues.
      Req.Test.stub(Email, fn conn ->
        send(test_pid, {:graph_send, conn.host, conn.path_info, conn.query_string})
        Plug.Conn.resp(conn, 202, "")
      end)

      conn = ms_graph_connection!(owner, client_secret: "s")
      %Ash.Union{type: :email, value: config} = conn.transport_config
      %Ash.Union{value: ms_graph} = adapter = config.adapter

      # A path/query-injection mailbox, forced past config validation, must still
      # not be able to alter the request path or add a query end-to-end.
      adapter_union = %{adapter | value: %{ms_graph | user_id: "x/../../beta/me?$top=1"}}

      event = %{delivery: %{"to" => ["rcpt@example.com"], "subject" => "hi", "text" => "body"}}

      assert {:ok, email} = Email.build_email(conn, event)
      assert {:ok, adapter, cfg} = Email.adapter_config(adapter_union, email)
      assert {:ok, _receipt} = adapter.deliver(email, cfg)

      assert_received {:graph_send, host, path_info, query_string}
      assert host == "graph.microsoft.com"
      # The mailbox stays a SINGLE decoded path segment; the path structure and the
      # (absent) query are intact regardless of what the mailbox contains.
      assert [root, "users", _mailbox, "sendMail"] = path_info
      assert root == "v1.0"
      assert query_string == ""
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp graph_email(from), do: Swoosh.Email.new() |> Swoosh.Email.from(from)

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
