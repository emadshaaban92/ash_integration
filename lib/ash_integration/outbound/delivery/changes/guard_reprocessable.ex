defmodule AshIntegration.Outbound.Delivery.Changes.GuardReprocessable do
  @moduledoc false
  # Precondition guard for `:reprocess`: pushes `… AND state != 'scheduled'` onto the
  # UPDATE so an in-flight row matches nothing and the write is a clean no-op (a
  # dropped `StaleRecord`).
  #
  # `:reprocess` resurrects a row back to `:pending` and `clear_claim()`s the
  # lease/backoff/terminal bookkeeping. Its legitimate sources are a build-parked row
  # (`:parked`, rebuilt by the `Reprocessor`), an operator "retry now" on a
  # waiting-to-retry/terminal `:failed` row, AND a still-`:pending` deliverable row
  # whose descriptor is re-derived after a transform edit (see `Reprocessor` +
  # `reprocessor_test`). The ONE state it must refuse is `:scheduled`: that row is
  # in-flight, claimed by the delivery relay under a `claimed_at` lease, and clearing
  # that lease would defeat the relay's fence and guarantee a duplicate delivery. So,
  # like every sibling relay-raced action (`:deliver`/`:record_failure`/
  # `:reset_to_pending` guard on `state == :scheduled`), this one carries the mirror
  # resource-level guard rather than trusting every caller (dashboard, Reprocessor, a
  # stale LiveView) to pre-check.
  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(state != :scheduled))
  end
end
