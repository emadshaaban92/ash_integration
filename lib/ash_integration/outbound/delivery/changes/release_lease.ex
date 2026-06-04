defmodule AshIntegration.Outbound.Delivery.Changes.ReleaseLease do
  @moduledoc false
  # Releases the soft lease (`claimed_at → nil`) on `:record_attempt_error`, while
  # leaving `next_attempt_at` (set from the backoff) intact. This decouples retry
  # timing from the lease: a row whose claimer recorded a failure is re-claimable
  # purely when its backoff elapses (`next_attempt_at <= now()`), not gated behind a
  # full lease window — otherwise a lease (sized ≫ the transport timeout for crash
  # detection) would swallow the early backoff steps. A claimer that instead CRASHES
  # mid-send records nothing, so its `claimed_at` stays set and the lease is what
  # bounds re-claim. Forced (not accepted) so callers never pass it.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :claimed_at, nil)
  end
end
