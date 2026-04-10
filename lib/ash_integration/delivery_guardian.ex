defmodule AshIntegration.DeliveryGuardian do
  @moduledoc """
  Periodically ensures delivery jobs and events are never permanently lost.

  - Rescues `discarded` jobs in the `integration_delivery` queue by
    resetting them to `available` with restored retry headroom.
  - Resets `max_attempts` on jobs that are approaching exhaustion,
    preventing them from being discarded in the first place.
  - Reconciles orphaned events: finds events in `scheduled` state with no
    corresponding Oban job (and not for suspended integrations), moves them
    back to `pending` so EventScheduler can re-create the delivery job.
  """

  use GenServer

  require Logger

  import Ecto.Query

  @default_interval :timer.seconds(30)
  @max_attempts 20
  # Events must be in `scheduled` state for at least this long before
  # being considered orphaned, to avoid racing with legitimately-executing jobs.
  @orphan_threshold_minutes 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_sweep(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    rescue_discarded()
    restore_headroom()
    reconcile_orphaned_events()
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  # Reset discarded delivery jobs back to available with full retry headroom.
  defp rescue_discarded do
    {count, _} =
      Oban.Job
      |> where([j], j.queue == "integration_delivery")
      |> where([j], j.state == "discarded")
      |> update([j],
        set: [
          state: "available",
          discarded_at: nil,
          scheduled_at: ^DateTime.utc_now(),
          max_attempts: j.attempt + @max_attempts
        ]
      )
      |> AshIntegration.repo().update_all([])

    if count > 0 do
      Logger.warning("DeliveryGuardian rescued #{count} discarded delivery job(s)")
    end
  end

  # Bump max_attempts on jobs waiting to run that are close to exhaustion,
  # preventing them from being discarded on the next failure.
  defp restore_headroom do
    {count, _} =
      Oban.Job
      |> where([j], j.queue == "integration_delivery")
      |> where([j], j.state in ["scheduled", "retryable"])
      |> where([j], j.max_attempts - j.attempt < 5)
      |> update([j], set: [max_attempts: j.attempt + @max_attempts])
      |> AshIntegration.repo().update_all([])

    if count > 0 do
      Logger.info("DeliveryGuardian restored retry headroom on #{count} delivery job(s)")
    end
  end

  # Find events in `scheduled` state that have no corresponding Oban job
  # and have been in that state for longer than the safety threshold.
  # Skip suspended integrations — those events are expected.
  defp reconcile_orphaned_events do
    repo = AshIntegration.repo()
    event_resource = AshIntegration.outbound_integration_event_resource()
    event_table = AshPostgres.DataLayer.Info.table(event_resource)
    integration_resource = AshIntegration.outbound_integration_resource()
    integration_table = AshPostgres.DataLayer.Info.table(integration_resource)
    threshold = DateTime.add(DateTime.utc_now(), -@orphan_threshold_minutes, :minute)

    # Find scheduled events with no active Oban job and non-suspended integration
    query = """
    SELECT e.id
    FROM #{event_table} e
    JOIN #{integration_table} i ON i.id = e.outbound_integration_id
    WHERE e.state = 'scheduled'
      AND e.updated_at < $1
      AND i.suspended = false
      AND NOT EXISTS (
        SELECT 1 FROM oban_jobs j
        WHERE j.queue = 'integration_delivery'
          AND j.state IN ('available', 'scheduled', 'executing', 'retryable')
          AND j.args->>'outbound_integration_event_id' = e.id::text
      )
    LIMIT 100
    """

    case repo.query(query, [threshold]) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: rows}} ->
        count = length(rows)

        Logger.warning(
          "DeliveryGuardian found #{count} orphaned event(s), moving back to pending"
        )

        event_ids = Enum.map(rows, fn [id] -> id end)

        # Move orphaned events back to pending so EventScheduler can
        # re-create delivery jobs for them. No Lua re-run needed — the
        # payload is already cached from the original dispatch.
        for event_id <- event_ids do
          case Ash.get(event_resource, event_id, authorize?: false) do
            {:ok, event} when event.state == :scheduled ->
              event
              |> Ash.Changeset.for_update(:reset_to_pending, %{}, authorize?: false)
              |> Ash.update(authorize?: false)
              |> case do
                {:ok, _} -> :ok
                {:error, _} -> :ok
              end

            _ ->
              :ok
          end
        end

        # Notify scheduler that events are ready
        AshIntegration.EventScheduler.notify()

      {:error, error} ->
        Logger.error("DeliveryGuardian: orphan reconciliation query failed: #{inspect(error)}")
    end
  end
end
