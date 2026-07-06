defmodule AshIntegration.Outbound.Delivery.Changes.GuardReprocessable do
  @moduledoc false
  # Precondition guard for `:reprocess`: pushes `… AND state IN ('pending', 'parked',
  # 'failed')` onto the UPDATE so a row outside that set matches nothing and the write
  # is a clean no-op (a dropped `StaleRecord`).
  #
  # `:reprocess` resurrects a row back to `:pending` and `clear_claim()`s the
  # lease/backoff/terminal bookkeeping. Its ONLY legitimate sources are:
  #
  #   * `:parked` — a build-failed row rebuilt by the `Reprocessor`;
  #   * `:failed` — an operator "retry now" on a waiting-to-retry/terminal head;
  #   * `:pending` — a deliverable row whose descriptor is re-derived after a
  #     transform edit (see `Reprocessor` + `reprocessor_test`).
  #
  # Every OTHER state is refused:
  #
  #   * `:scheduled` — in-flight, claimed under a `claimed_at` lease; clearing it
  #     would defeat the delivery relay's fence and duplicate the delivery;
  #   * `:delivered`/`:suppressed`/`:cancelled` — SETTLED. Resurrecting one re-sends
  #     already-final state; worst is a `:cancelled` (coalesced-away) row, which
  #     carries a SUPERSEDED body — reprocessing it re-derives and re-delivers stale
  #     state, potentially after its newer sibling already delivered (an ordering
  #     violation). An operator misclick from the dashboard must not be able to do
  #     that, so the guard enforces the exact documented source set rather than the
  #     looser "anything but in-flight". Like every sibling relay-raced action
  #     (`:deliver`/`:record_failure`/`:reset_to_pending`, guarded on `state ==
  #     :scheduled`), this is a resource-level guard, not a per-caller pre-check.
  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(state in [:pending, :parked, :failed]))
  end
end
