defmodule AshIntegration.Outbound.Delivery.Changes.EmitResumeTelemetry do
  @moduledoc false
  # After-action hook for the `:unsuspend` action. Emits the event named by the
  # `:event` opt, so the same change serves both
  # `[:ash_integration, :connection, :unsuspended]` and
  # `[:ash_integration, :subscription, :resumed]`.
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.fetch!(opts, :event)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      :telemetry.execute(event, %{count: 1}, %{id: record.id})
      {:ok, record}
    end)
  end
end
