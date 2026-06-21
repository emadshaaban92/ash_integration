defmodule AshIntegration.Inbound.Execute.Changes.GuardPending do
  @moduledoc false
  # Precondition guard for the relay/inline-raced finalizing writes
  # (`:apply_success`, `:apply_failure`, `:record_attempt_error`, `:dead_letter`):
  # pushes `… AND state = 'pending'` onto the UPDATE so a row that is no longer
  # `:pending` (already terminal, or re-claimed by another pass) matches nothing
  # and the write is a clean no-op. The caller layers a `claimed_at` lease-token
  # filter on top at its call site for the exact fence; this guard is the
  # resource-level backstop every caller inherits.
  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(state == :pending))
  end
end
