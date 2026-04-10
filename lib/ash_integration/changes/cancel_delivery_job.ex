defmodule AshIntegration.Changes.CancelDeliveryJob do
  @moduledoc """
  After-action hook for the `:cancel` action on OutboundIntegrationEvent.

  If the event was previously in `:scheduled` state, attempts to cancel the
  corresponding Oban delivery job. This is best-effort — the delivery worker
  also checks `event.state != :scheduled` as a guard.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      old_state = changeset.data.state

      if old_state == :scheduled do
        cancel_oban_job(record.id)
      end

      {:ok, record}
    end)
  end

  defp cancel_oban_job(event_id) do
    import Ecto.Query

    event_id_str = to_string(event_id)

    query =
      from(j in Oban.Job,
        where: j.queue == "integration_delivery",
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("?->>'outbound_integration_event_id' = ?", j.args, ^event_id_str)
      )

    case AshIntegration.repo().one(query) do
      nil ->
        :ok

      job ->
        case Oban.cancel_job(job.id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to cancel Oban job #{job.id} for event #{event_id}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end
end
