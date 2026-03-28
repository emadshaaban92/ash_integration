defmodule AshIntegration.Validations.HttpTimeout do
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    max = AshIntegration.http_max_timeout_ms()

    case Ash.Changeset.get_attribute(changeset, :timeout_ms) do
      nil ->
        :ok

      timeout_ms when timeout_ms > max ->
        {:error, field: :timeout_ms, message: "must not exceed #{max}ms"}

      _ ->
        :ok
    end
  end
end
