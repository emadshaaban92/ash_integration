defmodule AshIntegration.EventScheduler do
  @moduledoc """
  GenServer that finds `pending` events (with payload) and creates delivery
  jobs for them, respecting ordering per `(integration_id, resource_id)`.

  This is NOT an Oban worker. It runs under `AshIntegration.Supervisor` and
  uses adaptive scheduling: ~1 second when busy (triggered by dispatchers),
  10 seconds when idle (background sweep).

  The GenServer is an optimization — it reduces unnecessary DB queries. The
  correctness guarantee is the partial unique index on
  `(outbound_integration_id, resource_id) WHERE state = 'scheduled'`, which
  prevents double-scheduling regardless of how many scheduler instances exist.
  """
  use GenServer

  require Logger

  @idle_interval :timer.seconds(10)
  @min_run_interval_ms 1_000
  @batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Notify the scheduler that new events may be ready for scheduling.

  Uses cast (fire-and-forget). If the GenServer is down, the message is
  silently dropped — the 10-second self-timer will catch up once the
  process restarts. Do NOT change to GenServer.call.
  """
  def notify do
    GenServer.cast(__MODULE__, :schedule)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :schedule, @idle_interval)
    {:ok, %{last_run_at: 0, deferred: false}}
  end

  @impl true
  def handle_cast(:schedule, state) do
    {:noreply, maybe_run(state)}
  end

  @impl true
  def handle_info(:schedule, state) do
    {:noreply, maybe_run(state)}
  end

  defp maybe_run(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_run_at

    if elapsed >= @min_run_interval_ms do
      schedule_ready_events()
      Process.send_after(self(), :schedule, @idle_interval)
      %{state | last_run_at: now, deferred: false}
    else
      unless state.deferred do
        Process.send_after(self(), :schedule, @min_run_interval_ms - elapsed)
      end

      %{state | deferred: true}
    end
  end

  defp schedule_ready_events do
    ready_pairs = find_ready_pairs(@batch_size)
    process_pairs(ready_pairs)

    # If we filled the batch, there may be more work — loop immediately
    if length(ready_pairs) >= @batch_size do
      schedule_ready_events()
    end
  end

  defp process_pairs(ready_pairs) do
    event_resource = AshIntegration.outbound_integration_event_resource()

    for {integration_id, resource_id} <- ready_pairs do
      case event_resource
           |> Ash.Query.for_read(:next_pending, %{
             outbound_integration_id: integration_id,
             resource_id: resource_id
           })
           |> Ash.read(authorize?: false) do
        {:ok, [event | _]} ->
          if event.payload do
            case Ash.update(
                   Ash.Changeset.for_update(event, :schedule, %{}, authorize?: false),
                   authorize?: false
                 ) do
              {:ok, _} ->
                :ok

              {:error, _} ->
                # Constraint violation — someone else scheduled it, safe to skip
                :ok
            end
          else
            Logger.warning(
              "EventScheduler: event #{event.id} blocks chain " <>
                "(integration=#{integration_id}, resource=#{resource_id}) — " <>
                "payload is nil, run :reprocess to unblock"
            )
          end

        {:ok, []} ->
          :ok

        {:error, error} ->
          Logger.error("EventScheduler: failed to query next_pending: #{inspect(error)}")
      end
    end
  end

  @doc false
  def find_ready_pairs(batch_size) do
    repo = AshIntegration.repo()
    event_resource = AshIntegration.outbound_integration_event_resource()
    table = AshPostgres.DataLayer.Info.table(event_resource)
    integration_resource = AshIntegration.outbound_integration_resource()
    integration_table = AshPostgres.DataLayer.Info.table(integration_resource)

    query = """
    SELECT DISTINCT e.outbound_integration_id::text, e.resource_id
    FROM #{table} e
    JOIN #{integration_table} i ON i.id = e.outbound_integration_id
    WHERE e.state = 'pending'
      AND i.suspended = false
      AND NOT EXISTS (
        SELECT 1 FROM #{table} s
        WHERE s.outbound_integration_id = e.outbound_integration_id
          AND s.resource_id = e.resource_id
          AND s.state = 'scheduled'
      )
    LIMIT $1
    """

    case repo.query(query, [batch_size]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [integration_id, resource_id] ->
          {integration_id, resource_id}
        end)

      {:error, error} ->
        Logger.error("EventScheduler: find_ready_pairs failed: #{inspect(error)}")
        []
    end
  end
end
