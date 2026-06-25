defmodule AshIntegration.Outbound.Delivery.Changes.ParkOnSuspend do
  @moduledoc false
  # After-action on the `:suspend` transition (Connection/Subscription): revert the
  # entity's UN-LEASED `:scheduled` deliveries back to `:pending` so the relay stops
  # spending delivery slots on a dead endpoint. The predicate is the claim's own
  # "is this row free?" test, so a row a live worker is actively sending is left to
  # drain (you can't un-send it); a stale claimer's later finalize is fenced on the
  # old `claimed_at` token → a clean no-op. See design/connection-health.md §6.
  use Ash.Resource.Change

  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage

  @impl true
  def change(changeset, opts, _context) do
    column = Keyword.fetch!(opts, :column)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      park_unleased(column, record.id)
      {:ok, record}
    end)
  end

  defp park_unleased(column, id) do
    table = AshPostgres.DataLayer.Info.table(AshIntegration.event_delivery_resource())

    # Reset `attempts = 0` alongside the park: a suspension halt is not a transport
    # attempt, so the recovered entity resumes with a clean budget. This also parks
    # POISON rows (`attempts` at the ceiling) — left `:scheduled` they would block
    # the lane forever and keep the entity out of the recovery probe rotation; under
    # suspension the terminal verdict is forgiven, recovered like the rest.
    sql = """
    UPDATE #{table} SET state = 'pending', claimed_at = NULL, attempts = 0
    WHERE #{column} = $1
      AND state = 'scheduled'
      AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $2))
    """

    AshIntegration.repo().query!(
      sql,
      [Ecto.UUID.dump!(id), Stage.lease_seconds()],
      log: AshIntegration.query_log_level()
    )
  end
end
