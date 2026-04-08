defmodule AshIntegration.DeliveryGuardian do
  @moduledoc """
  Periodically ensures delivery jobs are never permanently lost.

  - Rescues `discarded` jobs in the `integration_delivery` queue by
    resetting them to `available` with restored retry headroom.
  - Resets `max_attempts` on jobs that are approaching exhaustion,
    preventing them from being discarded in the first place.
  """

  use GenServer

  require Logger

  import Ecto.Query

  @default_interval :timer.seconds(30)
  @max_attempts 20

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
end
