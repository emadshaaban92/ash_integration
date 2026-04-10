defmodule AshIntegration.Changes.InsertDeliveryJob do
  @moduledoc """
  After-action hook for the `:schedule` action on OutboundIntegrationEvent.

  Inserts an OutboundDelivery Oban job within the same database transaction
  as the state change to `:scheduled`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      %{event_id: record.id}
      |> AshIntegration.Workers.OutboundDelivery.new()
      |> Oban.insert!()

      {:ok, record}
    end)
  end
end
