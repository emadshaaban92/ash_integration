defmodule AshIntegration.Transport.Validations.RequireEncryptedArgument do
  @moduledoc """
  Validates that an AshCloak-managed argument is present.

  AshCloak renames encrypted attributes to `encrypted_<name>` and adds an argument
  with the original name. On create, the argument must be provided. On update,
  it may be omitted to keep the existing encrypted value.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, opts, _context) do
    field = opts[:field]
    encrypted_attr = String.to_existing_atom("encrypted_#{field}")

    # `fetch_argument` returns `{:ok, nil}` for an argument explicitly provided as
    # nil — which is NOT a real secret. Guarding on `not is_nil(value)` makes both
    # an explicit nil and an omitted argument fall through to the encrypted-attribute
    # check, so a create with `%{value: nil}` is rejected instead of saving a
    # secret-less credential (a "Bearer " with no token).
    case Ash.Changeset.fetch_argument(changeset, field) do
      {:ok, value} when not is_nil(value) ->
        :ok

      _ ->
        if Ash.Changeset.get_attribute(changeset, encrypted_attr) do
          :ok
        else
          {:error, field: field, message: "is required"}
        end
    end
  end
end
