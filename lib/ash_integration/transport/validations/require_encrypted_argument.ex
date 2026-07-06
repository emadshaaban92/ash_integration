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

    # A real secret is a NON-BLANK string argument. `fetch_argument` returns
    # `{:ok, nil}` for an explicit nil and `{:ok, ""}` for an explicit empty string;
    # both — and a whitespace-only value — would save with no meaningful ciphertext
    # and make the transport send an empty credential (a bare "Bearer " / an empty
    # api-key header), the exact secret-less config this validation exists to
    # prevent. Anything that isn't a real secret falls through to the
    # encrypted-attribute check (so an update that omits the argument still keeps
    # the existing encrypted value).
    if present_secret?(Ash.Changeset.fetch_argument(changeset, field)) do
      :ok
    else
      if Ash.Changeset.get_attribute(changeset, encrypted_attr) do
        :ok
      else
        {:error, field: field, message: "is required"}
      end
    end
  end

  defp present_secret?({:ok, value}) when is_binary(value), do: String.trim(value) != ""
  defp present_secret?(_), do: false
end
