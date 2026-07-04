defmodule AshIntegration.Outbound.Delivery.Changes.ClearClaim do
  @moduledoc false
  # Clears the delivery relay's lease + backoff bookkeeping (`claimed_at`,
  # `next_attempt_at`) AND the terminal verdict (`terminal_reason`) whenever a row
  # (re-)enters the deliverable lifecycle — on `:schedule` (`pending`/`:failed →
  # :scheduled`), `:reprocess` (operator resurrection back to `:pending`), and
  # `:reset_to_pending` (operator recourse) — so it doesn't inherit a stale
  # `claimed_at` (which would delay the relay's first claim), a spent
  # `next_attempt_at` backoff cursor, or a stale terminal verdict. Without the
  # `terminal_reason` clear, a resurrected terminal row that then failed retryably
  # would land back in `:failed` with the old verdict still set — silently terminal
  # again, with no `:terminal` telemetry and no operator signal.
  #
  # It does NOT touch `attempts`. In this model `attempts` is an honest, MONOTONIC
  # count of delivery claims, never forced or reset — terminal-ness lives in
  # `terminal_reason`, not in an inflated/cleared counter, so zeroing the count on a
  # reschedule would only make `attempts` lie. Forced (not accepted) so callers never
  # have to pass these.
  #
  # `atomic/3` mirrors `change/2` exactly so the scheduler can bulk-promote `:failed`
  # heads in one atomic UPDATE (`Ash.bulk_update` with an `:atomic` strategy).
  use Ash.Resource.Change

  @cleared %{claimed_at: nil, next_attempt_at: nil, terminal_reason: nil}

  @impl true
  def change(changeset, _opts, _context) do
    Enum.reduce(@cleared, changeset, fn {attribute, value}, changeset ->
      Ash.Changeset.force_change_attribute(changeset, attribute, value)
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, @cleared}
  end
end
