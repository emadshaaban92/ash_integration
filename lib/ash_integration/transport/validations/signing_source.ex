defmodule AshIntegration.Transport.Validations.SigningSource do
  @moduledoc false
  # Create/update validation for a `custom` signing scheme: reject a `source` that
  # can't be saved (size/parse), at save time, with a readable field error — rather
  # than letting a broken script reach delivery and fail every send. Mirrors the
  # transform's `Validations.TransformSource`, but parse-only: signing has no
  # producer `example/1` to smoke-run against, so there is no sample-based layer.
  use Ash.Resource.Validation

  alias AshIntegration.Outbound.Delivery.Transform.Runtime

  @impl true
  def validate(changeset, _opts, _context) do
    # Stay cheap when the script isn't changing (e.g. a parent update touching
    # other fields): only parse-check when `source` is actually changing.
    if Ash.Changeset.changing_attribute?(changeset, :source) do
      validate_source(changeset)
    else
      :ok
    end
  end

  defp validate_source(changeset) do
    case value(changeset, :source) do
      source when is_binary(source) and source != "" ->
        check(Runtime.validate(runtime(changeset), source))

      _ ->
        :ok
    end
  end

  defp check(:ok), do: :ok
  defp check({:error, message}), do: {:error, field: :source, message: message}

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "signing script validation runs in the signing runtime"}

  defp runtime(changeset) do
    case value(changeset, :runtime) do
      runtime when is_atom(runtime) and not is_nil(runtime) -> runtime
      _ -> Runtime.default_runtime()
    end
  end

  defp value(changeset, attribute) do
    case Map.fetch(changeset.attributes, attribute) do
      {:ok, value} -> value
      :error -> Map.get(changeset.data, attribute)
    end
  end
end
