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

  defp email_connection!(owner, opts) do
    adapter =
      %{type: "smtp", relay: "smtp.acme.com", port: 2525, username: "u", tls: :always}
      |> maybe_put(:password, opts[:password])

    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "email-#{System.unique_integer([:positive])}",
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
      %{email: "ec-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end
end
