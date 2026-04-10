defmodule AshIntegration.Changes.SetSuspensionDetails do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    reason = Ash.Changeset.get_argument(changeset, :reason)

    changeset
    |> Ash.Changeset.force_change_attribute(:suspended_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:suspension_reason, reason)
  end
end
