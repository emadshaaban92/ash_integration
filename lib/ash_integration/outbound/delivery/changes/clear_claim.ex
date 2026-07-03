defmodule AshIntegration.Outbound.Delivery.Changes.ClearClaim do
  @moduledoc false
  # Clears the delivery relay's lease + backoff bookkeeping (`claimed_at`,
  # `next_attempt_at`) whenever a row is (re-)promoted or reset — on `:schedule`
  # (`pending`/`:failed → :scheduled`) and `:reset_to_pending` (operator recourse) — so
  # it doesn't inherit a stale `claimed_at` (which would delay the relay's first claim)
  # or a spent `next_attempt_at` backoff cursor.
  #
  # It does NOT touch `attempts`. In this model `attempts` is an honest, MONOTONIC
  # count of delivery claims, never forced or reset — terminal-ness lives in
  # `terminal_reason`, not in an inflated/cleared counter, so zeroing the count on a
  # reschedule would only make `attempts` lie. Forced (not accepted) so callers never
  # have to pass these.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:claimed_at, nil)
    |> Ash.Changeset.force_change_attribute(:next_attempt_at, nil)
  end
end
