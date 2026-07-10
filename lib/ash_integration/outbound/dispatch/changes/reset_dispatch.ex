defmodule AshIntegration.Outbound.Dispatch.Changes.ResetDispatch do
  @moduledoc false
  # Clears the terminal bookkeeping on an Event so a stuck/poison (`:expired`) one
  # becomes claimable again (operator recourse): `dispatch_terminal_reason` → nil
  # (no longer terminal, so `claim/1` picks it up), `claimed_at`/`dispatch_error` →
  # nil. Deliberately does NOT reset `dispatch_attempts` — the count is a monotonic,
  # honest history (mirrors `EventDelivery.attempts`) and, with no attempt ceiling,
  # no longer gates the claim. Deliberately leaves `dispatched_at` alone, so an
  # already-dispatched Event stays out of the outbox and the reset is a harmless
  # no-op. The relay re-claims on its next poll — no notify needed.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:dispatch_terminal_reason, nil)
    |> Ash.Changeset.force_change_attribute(:claimed_at, nil)
    |> Ash.Changeset.force_change_attribute(:dispatch_error, nil)
  end
end
