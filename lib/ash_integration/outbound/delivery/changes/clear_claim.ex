defmodule AshIntegration.Outbound.Delivery.Changes.ClearClaim do
  @moduledoc false
  # Clears the delivery relay's lease + backoff bookkeeping (`claimed_at`,
  # `next_attempt_at`) AND the attempt count (`attempts`) whenever a row (re-)enters
  # a claimable lifecycle — on `:schedule` (`pending → scheduled`) and
  # `:reset_to_pending` (suspension halt / operator recourse). Without the lease/
  # backoff reset a re-promoted row could inherit a stale `claimed_at` or
  # `next_attempt_at` and be delayed by a lease/backoff window.
  #
  # The `attempts` reset is what keeps suspension from poisoning a delivery: a claim
  # bumps `attempts`, but a suspended entity's failed delivery is one-shot back to
  # `:pending` (the recovery probe paces the next try) rather than retried in place —
  # without clearing the count, those probe attempts would march the row to the
  # poison ceiling and strand it `:scheduled` after recovery. On `:schedule` the reset
  # is a harmless no-op (a freshly promoted head has not accrued claims). Forced (not
  # accepted) so callers never have to pass these.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:claimed_at, nil)
    |> Ash.Changeset.force_change_attribute(:next_attempt_at, nil)
    |> Ash.Changeset.force_change_attribute(:attempts, 0)
  end
end
