defmodule AshIntegration.Inbound.Execute.Changes.ClearClaim do
  @moduledoc false
  # Clears the relay's lease + backoff bookkeeping (`claimed_at`,
  # `next_attempt_at`) whenever a row re-enters a claimable lifecycle — on
  # `:retry` (`dead_lettered → pending`). Without this, a re-queued row could
  # inherit a stale `claimed_at` (delaying re-claim by a lease window) or a stale
  # `next_attempt_at` (delaying it by a backoff window). Forced (not accepted) so
  # callers never pass these.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:claimed_at, nil)
    |> Ash.Changeset.force_change_attribute(:next_attempt_at, nil)
  end
end
