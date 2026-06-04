defmodule AshIntegration.Outbound.Delivery.Changes.GuardScheduled do
  @moduledoc false
  # Precondition guard for the relay-raced write actions (`:deliver`,
  # `:record_attempt_error`, `:reset_to_pending`): pushes `… AND state = 'scheduled'`
  # onto the UPDATE so a row that is no longer `:scheduled` matches nothing and the
  # write is a clean no-op.
  #
  # Under the delivery relay's `FOR UPDATE SKIP LOCKED` + soft-lease concurrency a
  # stale claimer (its lease expired and another pass re-claimed, cancelled, or
  # reset the row) must NOT finalize it — finalizing a `:cancelled`/`:pending` row
  # back to `:delivered` would resurrect it and break ordering. Under the old
  # Oban + Guardian (10-minute orphan threshold) this race was near-impossible; the
  # lease window makes it real, so the guard is now load-bearing. The relay layers a
  # `claimed_at` lease-token filter on top of this at its call site for the exact
  # fence; this guard is the resource-level backstop that every caller inherits.
  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(state == :scheduled))
  end
end
