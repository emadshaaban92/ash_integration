defmodule AshIntegration.Actions.BulkReprocess do
  @moduledoc """
  Generic action implementation for `:bulk_reprocess` on OutboundIntegration.

  Streams all `pending` events with `payload: nil` for the given integration,
  re-runs the current Lua script inline for each, and updates the event.
  Returns `%{reprocessed: n, failed: n}`.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias AshIntegration.LuaSandbox

  @impl true
  def run(input, _opts, _context) do
    integration = input.arguments.integration
    event_resource = AshIntegration.outbound_integration_event_resource()

    {reprocessed, failed} =
      event_resource
      |> Ash.Query.for_read(:stale_pending, %{outbound_integration_id: integration.id})
      |> Ash.stream!(authorize?: false)
      |> Enum.reduce({0, 0}, fn event, {ok_count, err_count} ->
        case reprocess_event(integration, event) do
          :ok -> {ok_count + 1, err_count}
          :error -> {ok_count, err_count + 1}
        end
      end)

    # Notify scheduler that events may have been unblocked
    if reprocessed > 0 do
      AshIntegration.EventScheduler.notify()
    end

    {:ok, %{reprocessed: reprocessed, failed: failed}}
  end

  defp reprocess_event(integration, event) do
    # Build the event structure for Lua
    event_for_lua =
      AshIntegration.OutboundIntegrations.Info.build_event(%{
        id: event.id,
        resource: event.resource,
        action: event.action,
        schema_version: integration.schema_version,
        occurred_at: event.occurred_at,
        data: event.snapshot
      })

    case LuaSandbox.execute(integration.transform_script, event_for_lua) do
      {:ok, :skip} ->
        # Cancel events that the script now skips
        event
        |> Ash.Changeset.for_update(:cancel, %{}, authorize?: false)
        |> Ash.update(authorize?: false)

        :ok

      {:ok, payload} ->
        event
        |> Ash.Changeset.for_update(
          :reprocess,
          %{payload: payload, last_error: nil},
          authorize?: false
        )
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end

      {:error, lua_error} ->
        event
        |> Ash.Changeset.for_update(
          :reprocess,
          %{payload: nil, last_error: "Lua error: #{lua_error}"},
          authorize?: false
        )
        |> Ash.update(authorize?: false)

        :error
    end
  end
end
