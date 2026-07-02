defmodule AshIntegration.Outbound.Delivery.Changes.MarkTerminal do
  @moduledoc false
  # Forces `attempts` up to the poison ceiling (`Supervisor.max_attempts/0`) so a
  # row is immediately terminal: `Dispatcher.claim/1`'s `attempts < max_attempts`
  # gate never re-picks it, `Dispatcher.poison?/1` reports it as terminal, and the
  # dashboard poison view buckets it — all without a new state or column.
  #
  # Used by `:record_permanent_failure`, where the transport reported a NON-retryable
  # `:response`-class rejection (`retryable: false` — a deterministic HTTP 4xx/3xx the
  # target refuses regardless of its health) that a retry cannot fix.
  # Unlike the ordinary poison ceiling (reached by exhausting `max_attempts` real
  # attempts) this takes the row terminal on the FIRST such failure, so the row is
  # left `:scheduled` with its lane blocked (preserving per-key order) instead of
  # marching through backoff/suspension/probe cycles it can never clear. Forced (not
  # accepted) so callers never pass it.
  use Ash.Resource.Change

  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :attempts, Stage.max_attempts())
  end
end
