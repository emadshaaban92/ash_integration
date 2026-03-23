defmodule AshIntegration.Changes.PublishEvent do
  use Ash.Resource.Change

  require Ash.Tracer

  alias AshIntegration.OutboundIntegrations.Info

  @impl true
  def batch_change(changesets, _opts, _context) do
    changesets
  end

  @impl true
  def after_batch(changesets_and_results, _opts, _context)
      when changesets_and_results != [] do
    {changeset, _} = List.first(changesets_and_results)

    if Info.supports_action?(changeset.resource, changeset.action.name) do
      resource = Info.resource_identifier(changeset.resource)
      action = to_string(changeset.action.name)

      Ash.Tracer.span :custom, "PublishEvent", changeset.context[:private][:tracer] do
        changesets_and_results
        |> Enum.map(fn {_changeset, record} ->
          AshIntegration.Workers.EventDispatcher.new(%{
            event_id: Ash.UUIDv7.generate(),
            resource: resource,
            action: action,
            resource_id: record.id,
            occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })
        end)
        |> Oban.insert_all()
      end
    end

    :ok
  end

  def after_batch(_, _, _), do: :ok
end
