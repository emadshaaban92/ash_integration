defmodule AshIntegration.Outbound.Delivery.Changes.SetSuspensionDetails do
  @moduledoc false
  # Stamps `suspended_at`, `suspension_reason`, and `suspension_source` when a
  # Connection or Subscription is suspended. Shared by both resources' `:suspend`
  # actions. `suspension_source` records WHO suspended it (`:auto` derived health,
  # `:manual` operator, `:parked` opt-in parked backlog) so the derived-health
  # recompute can unwind only its own (`:auto`) suspensions and never a manual or
  # parked one. Defaults to `:manual` — the action's argument default — so a bare
  # operator `suspend` is correctly tagged manual.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    reason = Ash.Changeset.get_argument(changeset, :reason)
    source = Ash.Changeset.get_argument(changeset, :source) || :manual

    changeset
    |> Ash.Changeset.force_change_attribute(:suspended_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:suspension_reason, reason)
    |> Ash.Changeset.force_change_attribute(:suspension_source, source)
  end
end
