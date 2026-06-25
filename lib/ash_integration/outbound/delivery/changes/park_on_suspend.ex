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

    # Poison rows (attempts at the ceiling) are left `:scheduled`, lane blocked —
    # the terminal policy is unchanged; only the live backlog is parked. Forgiving
    # them here would resurrect a known-dead head as `:pending`, and since the probe
    # promotes the oldest schedulable head first, that head would starve the entity's
    # healthy lanes out of the recovery rotation. A re-promoted parked row still gets
    # a clean attempt budget — `ClearClaim` zeroes `attempts` on the `:schedule` that
    # re-promotes it — so this leaves no poison-on-reschedule trap.
    sql = """
    UPDATE #{table} SET state = 'pending', claimed_at = NULL
    WHERE #{column} = $1
      AND state = 'scheduled'
      AND attempts < $2
      AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $3))
    """

    AshIntegration.repo().query!(
      sql,
      [Ecto.UUID.dump!(id), Stage.max_attempts(), Stage.lease_seconds()],
      log: AshIntegration.query_log_level()
    )
  end
end
