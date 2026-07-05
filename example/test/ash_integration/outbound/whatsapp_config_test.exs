defmodule Example.Outbound.WhatsAppConfigTest do
  @moduledoc """
  The WhatsApp transport's Meta Cloud access token is encrypted at rest (AshCloak)
  exactly like the HTTP bearer token, Kafka SASL password, and SMTP password: the
  plaintext never lands in the stored column, and the transport decrypts it live
  via `Utils.load_secret/3`.
  """
  use Example.DataCase, async: false

  alias AshIntegration.Transport.Utils
  alias Example.Outbound.Connection

  setup do
    %{owner: create_user!()}
  end

  test "the access token is stored encrypted and decrypts live", %{owner: owner} do
    conn = whatsapp_connection!(owner, access_token: "EAAG-secret-token")

    %Ash.Union{type: :whatsapp, value: config} = conn.transport_config
    %Ash.Union{type: :meta_cloud, value: adapter} = config.adapter

    # Encrypted at rest, plaintext not on the struct.
    assert adapter.encrypted_access_token != nil
    refute Map.get(adapter, :access_token) == "EAAG-secret-token"

    # The live carve-out path the transport uses decrypts it.
    assert {:ok, loaded} = Utils.load_secret(adapter, [:access_token], "WhatsApp access token")
    assert loaded.access_token == "EAAG-secret-token"

    # Non-secret config is stored as given, with the version default applied.
    assert adapter.phone_number_id == "123456789012345"
    assert adapter.api_version == "v21.0"
    assert adapter.business_account_id == "998877"
  end

  test "the access token is required on create", %{owner: owner} do
    assert {:error, error} =
             Connection
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "wa-#{System.unique_integer([:positive])}",
                 owner_id: owner.id,
                 transport_config: %{
                   type: :whatsapp,
                   adapter: %{type: "meta_cloud", phone_number_id: "123"}
                 }
               },
               authorize?: false
             )
             |> Ash.create()

    assert Exception.message(error) =~ "access_token"
  end

  defp whatsapp_connection!(owner, opts) do
    adapter =
      %{
        type: "meta_cloud",
        phone_number_id: "123456789012345",
        access_token: opts[:access_token],
        business_account_id: "998877"
      }

    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "wa-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{type: :whatsapp, adapter: adapter}
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
