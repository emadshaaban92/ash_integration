defmodule AshIntegration.Transport.Validations.CacertPem do
  @moduledoc false
  # Create/update validation for a private-CA `cacert_pem`: reject a value that
  # decodes to no PEM certificate AT SAVE TIME, with the same message the runtime
  # builder would produce — rather than letting a bad paste save cleanly and only
  # surface as a non-retryable transport failure on the first event delivery (with
  # events parking until someone fixes it). The cert is static, user-pasted data,
  # so it can be checked once at save. Mirrors `Validations.SigningSource`.
  use Ash.Resource.Validation

  alias AshIntegration.Transport.TlsOptions

  @impl true
  def validate(changeset, _opts, _context) do
    # Stay cheap when the cert isn't changing (e.g. a parent update touching other
    # fields): only decode-check when `cacert_pem` is actually changing.
    if Ash.Changeset.changing_attribute?(changeset, :cacert_pem) do
      check(TlsOptions.validate_cacert_pem(value(changeset, :cacert_pem)))
    else
      :ok
    end
  end

  defp check(:ok), do: :ok
  defp check({:error, message}), do: {:error, field: :cacert_pem, message: message}

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "cacert_pem PEM decoding runs outside the data layer"}

  defp value(changeset, attribute) do
    case Map.fetch(changeset.attributes, attribute) do
      {:ok, value} -> value
      :error -> Map.get(changeset.data, attribute)
    end
  end
end
