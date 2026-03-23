defmodule AshIntegration.Changes.AutoDeactivateOnFailures do
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      threshold = AshIntegration.auto_deactivation_threshold()

      if record.consecutive_failures >= threshold and record.active do
        Logger.warning(
          "Outbound integration #{record.id} auto-deactivated after #{record.consecutive_failures} consecutive failures"
        )

        record
        |> Ash.Changeset.for_update(:auto_deactivate, %{}, authorize?: false)
        |> Ash.update(authorize?: false)
      else
        {:ok, record}
      end
    end)
  end
end
