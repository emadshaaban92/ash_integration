defmodule AshIntegration.Outbound.Dispatch.Changes.ResetDispatch do
  @moduledoc false
  # Clears the relay bookkeeping on an Event so a stuck/poison one becomes claimable
  # again (operator recourse): `dispatch_attempts` → 0 (full retry budget),
  # `claimed_at`/`dispatch_error` → nil. Deliberately leaves `dispatched_at` alone,
  # so an already-dispatched Event stays out of the outbox and the reset is a
  # harmless no-op. The relay re-claims on its next poll — no notify needed.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:dispatch_attempts, 0)
    |> Ash.Changeset.force_change_attribute(:claimed_at, nil)
    |> Ash.Changeset.force_change_attribute(:dispatch_error, nil)
  end
end
