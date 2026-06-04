defmodule AshIntegration.Outbound.Delivery.Changes.ClearClaim do
  @moduledoc false
  # Clears the delivery relay's lease + backoff bookkeeping (`claimed_at`,
  # `next_attempt_at`) whenever a row (re-)enters a claimable lifecycle — on
  # `:schedule` (`pending → scheduled`) and `:reset_to_pending` (suspension halt /
  # operator recourse). Without this, a row re-promoted after a previous claim could
  # inherit a stale `claimed_at` (delaying re-claim by up to a lease window) or a
  # stale `next_attempt_at` (delaying it by a backoff window). Forced (not accepted)
  # so callers never have to pass these.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:claimed_at, nil)
    |> Ash.Changeset.force_change_attribute(:next_attempt_at, nil)
  end
end
