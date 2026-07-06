defmodule AshIntegration.Transport.SecretValidationsTest do
  @moduledoc """
  Save-time validations on the embedded secret-bearing resources:

    * `RequireEncryptedArgument` must reject an **explicit nil** secret, not just an
      omitted one — otherwise an AshCloak-managed secret saves with no ciphertext and
      the transport sends an empty credential (a bare `"Bearer "`).
    * `HeaderName` must reject a control character (CR/LF/DEL) in a header name that
      is injected verbatim into the outbound request — the same trust boundary the
      `custom` signing scheme enforces on script-built headers.

  These assert on the changeset built by `Ash.Changeset.for_create/3` (which runs the
  validations) so they exercise the real resource config without a live vault — the
  encrypted round-trip itself is covered in the example app.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Transport.HttpAuth.ApiKey
  alias AshIntegration.Transport.OAuth2.ClientCredentials
  alias AshIntegration.Transport.Signing.Stripe

  defp error_on?(changeset, field) do
    Enum.any?(changeset.errors, fn
      %{field: ^field} -> true
      _ -> false
    end)
  end

  describe "RequireEncryptedArgument rejects an explicit nil secret" do
    test "api key created with an explicit nil value is invalid" do
      changeset =
        Ash.Changeset.for_create(ApiKey, :create, %{header_name: "X-API-Key", value: nil})

      refute changeset.valid?
      assert error_on?(changeset, :value)
    end

    test "stripe signing created with an explicit nil secret is invalid" do
      changeset = Ash.Changeset.for_create(Stripe, :create, %{secret: nil})

      refute changeset.valid?
      assert error_on?(changeset, :secret)
    end

    test "oauth2 client credentials created with an explicit nil client_secret is invalid" do
      changeset =
        Ash.Changeset.for_create(ClientCredentials, :create, %{
          token_url: "https://login.test/oauth2/token",
          client_id: "abc",
          client_secret: nil
        })

      refute changeset.valid?
      assert error_on?(changeset, :client_secret)
    end

    test "an explicit empty-string secret is invalid (same secret-less credential as nil)" do
      changeset =
        Ash.Changeset.for_create(ApiKey, :create, %{header_name: "X-API-Key", value: ""})

      refute changeset.valid?
      assert error_on?(changeset, :value)
    end

    test "a whitespace-only secret is invalid" do
      changeset = Ash.Changeset.for_create(Stripe, :create, %{secret: "   "})

      refute changeset.valid?
      assert error_on?(changeset, :secret)
    end

    test "a real (non-nil) secret still passes the presence check" do
      changeset =
        Ash.Changeset.for_create(ApiKey, :create, %{header_name: "X-API-Key", value: "k"})

      refute error_on?(changeset, :value)
    end
  end

  describe "HeaderName rejects control characters in an injected header name" do
    test "api key header_name with an embedded CRLF is invalid" do
      changeset =
        Ash.Changeset.for_create(ApiKey, :create, %{
          header_name: "X-API-Key\r\nEvil: 1",
          value: "k"
        })

      refute changeset.valid?
      assert error_on?(changeset, :header_name)
    end

    test "stripe signing header_name with an embedded control char is invalid" do
      changeset =
        Ash.Changeset.for_create(Stripe, :create, %{header_name: "Bad\x00Name", secret: "s"})

      refute changeset.valid?
      assert error_on?(changeset, :header_name)
    end

    test "an ordinary header name passes" do
      changeset =
        Ash.Changeset.for_create(ApiKey, :create, %{header_name: "X-Custom-Key", value: "k"})

      refute error_on?(changeset, :header_name)
    end
  end
end
