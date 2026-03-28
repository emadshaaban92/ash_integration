defmodule AshIntegration.Validations.RequireEncryptedArgument do
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

    case Ash.Changeset.fetch_argument(changeset, field) do
      {:ok, _value} ->
        :ok

      :error ->
        if Ash.Changeset.get_attribute(changeset, encrypted_attr) do
          :ok
        else
          {:error, field: field, message: "is required"}
        end
    end
  end
end
