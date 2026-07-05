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

  test "a phone_number_id with a control character is rejected at save (not at send)", %{
    owner: owner
  } do
    # A CR/LF or space in phone_number_id would be interpolated into the Graph URL
    # and make Req/Mint RAISE while building the request target — a crash-loop the
    # send path can't rescue. The `match:` constraint rejects it as a field error.
    assert {:error, error} = create_whatsapp_connection(owner, phone_number_id: "123\r\n456")

    assert Exception.message(error) =~ "phone_number_id"
  end

  test "a non-numeric phone_number_id is rejected at save", %{owner: owner} do
    assert {:error, error} = create_whatsapp_connection(owner, phone_number_id: "123 456")

    assert Exception.message(error) =~ "phone_number_id"
  end

  test "a malformed api_version is rejected at save", %{owner: owner} do
    # Anything but `v<major>.<minor>` (e.g. a value carrying whitespace/CR-LF) is
    # rejected before it can crash the send by corrupting the request target.
    assert {:error, error} = create_whatsapp_connection(owner, api_version: "v21.0 evil")

    assert Exception.message(error) =~ "api_version"
  end

  test "a well-formed phone_number_id and api_version save cleanly", %{owner: owner} do
    conn =
      whatsapp_connection!(owner, access_token: "EAAG-secret-token")

    %Ash.Union{type: :whatsapp, value: config} = conn.transport_config
    %Ash.Union{type: :meta_cloud, value: adapter} = config.adapter

    assert adapter.phone_number_id == "123456789012345"
    assert adapter.api_version == "v21.0"
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
    case create_whatsapp_connection(owner, opts) do
      {:ok, conn} -> conn
      {:error, error} -> raise error
    end
  end

  defp create_whatsapp_connection(owner, opts) do
    adapter =
      %{
        type: "meta_cloud",
        phone_number_id: Keyword.get(opts, :phone_number_id, "123456789012345"),
        api_version: Keyword.get(opts, :api_version, "v21.0"),
        access_token: Keyword.get(opts, :access_token, "EAAG-secret-token"),
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
    |> Ash.create(authorize?: false)
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
