defmodule AshIntegration.Inbound.Execute.Changes.GuardDeadLettered do
  @moduledoc false
  # Precondition guard for the operator `:retry` action: pushes
  # `… AND state = 'dead_lettered'` onto the UPDATE so `:retry` can only ever
  # un-stick a genuine dead letter (a concurrent retry, or a row that is no longer
  # dead-lettered, matches nothing and the write is a clean no-op).
  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(state == :dead_lettered))
  end
end
