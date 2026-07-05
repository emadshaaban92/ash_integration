defmodule Example.Outbound.EmailConfigTest do
  @moduledoc """
  The Email transport's SMTP credential is encrypted at rest (AshCloak) exactly
  like the HTTP bearer token and Kafka SASL password: the plaintext never lands in
  the stored column, and the transport decrypts it live via `Utils.load_secret/3`.
  """
  use Example.DataCase, async: false

  alias AshIntegration.Transport.Utils
  alias Example.Outbound.Connection

  setup do
    %{owner: create_user!()}
  end

  test "the SMTP password is stored encrypted and decrypts live", %{owner: owner} do
    conn = email_connection!(owner, password: "hunter2")

    %Ash.Union{type: :email, value: config} = conn.transport_config
    %Ash.Union{type: :smtp, value: smtp} = config.adapter

    # Encrypted at rest, plaintext not on the struct.
    assert smtp.encrypted_password != nil
    refute Map.get(smtp, :password) == "hunter2"

    # The live carve-out path the transport uses decrypts it.
    assert {:ok, loaded} = Utils.load_secret(smtp, [:password], "SMTP password")
    assert loaded.password == "hunter2"

    # Non-secret config is stored as given.
    assert smtp.relay == "smtp.acme.com"
    assert smtp.port == 2525
    assert smtp.tls == :always
  end

  test "an SMTP server without auth (no password) is valid", %{owner: owner} do
    conn = email_connection!(owner, password: nil)

    %Ash.Union{type: :email, value: config} = conn.transport_config
    %Ash.Union{type: :smtp, value: smtp} = config.adapter
    assert smtp.encrypted_password == nil
    assert {:ok, loaded} = Utils.load_secret(smtp, [:password], "SMTP password")
    assert loaded.password == nil
  end

  describe "from / user_id format validation" do
    test "rejects a from whose address carries a path metacharacter", %{owner: owner} do
      assert {:error, error} = email_connection(owner, from: "bot/../../x@acme.com")
      assert error_on_field?(error, :from)
    end

    test "rejects a from with an embedded space (request-forgery vector)", %{owner: owner} do
      assert {:error, error} = email_connection(owner, from: "bot @acme.com")
      assert error_on_field?(error, :from)
    end

    test "accepts a plain address and a display-name from", %{owner: owner} do
      assert {:ok, _} = email_connection(owner, from: "bot@acme.com")
      assert {:ok, _} = email_connection(owner, from: "Acme Bot <bot@acme.com>")
    end

    test "rejects an ms_graph user_id with a path/query metacharacter", %{owner: owner} do
      assert {:error, error} = ms_graph_connection(owner, user_id: "shared/../../beta/x?p=1")
      assert error_on_field?(error, :user_id)
    end

    test "accepts a plausible ms_graph user_id (UPN)", %{owner: owner} do
      assert {:ok, _} = ms_graph_connection(owner, user_id: "shared@acme.com")
    end
  end

  defp email_connection(owner, opts) do
    adapter =
      %{type: "smtp", relay: "smtp.acme.com", port: 2525, username: "u", tls: :always}
      |> maybe_put(:password, opts[:password])

    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "email-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :email,
          from: opts[:from] || "bot@acme.com",
          adapter: adapter
        }
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  defp email_connection!(owner, opts) do
    {:ok, conn} = email_connection(owner, opts)
    conn
  end

  defp ms_graph_connection(owner, opts) do
    oauth2 = %{
      token_url: "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
      client_id: "cid",
      client_secret: "s",
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
    |> Ash.create(authorize?: false)
  end

  defp error_on_field?(%Ash.Error.Invalid{errors: errors}, field) do
    Enum.any?(errors, fn err -> Map.get(err, :field) == field end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "ec-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end
end
