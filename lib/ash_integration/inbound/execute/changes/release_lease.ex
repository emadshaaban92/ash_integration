defmodule AshIntegration.Inbound.Execute.Changes.ReleaseLease do
  @moduledoc false
  # Releases the soft lease (`claimed_at → nil`) on a finalizing write so a
  # re-claim (or, for a transient retry, the durable `next_attempt_at` backoff)
  # governs when the row is next picked up — never a stale lease stamp. Forced (not
  # accepted) so callers never pass it.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :claimed_at, nil)
  end
end
