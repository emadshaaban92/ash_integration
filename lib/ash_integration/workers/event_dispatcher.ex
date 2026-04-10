defmodule AshIntegration.Workers.EventDispatcher do
  @moduledoc """
  Oban worker that creates OutboundIntegrationEvent records for matching
  integrations when a source change occurs.

  Finds all matching integrations (including suspended ones — events are always
  created to prevent data loss). Loads event data, runs Lua transform inline,
  and creates an event record with the cached payload. If Lua fails, the event
  is created with `payload: nil` and `last_error` set — it's stuck until
  manual `:reprocess`.

  After creating events, notifies EventScheduler to trigger scheduling.
  """
  use Oban.Worker,
    queue: :integration_dispatch,
    max_attempts: 3,
    unique: [keys: [:event_id]]

  require Ash.Query
  require Logger

  alias AshIntegration.{EventDataLoader, LuaSandbox}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "event_id" => event_id,
          "resource" => resource,
          "action" => action,
          "resource_id" => resource_id,
          "occurred_at" => occurred_at
        }
      }) do
    outbound_integrations = find_matching_outbound_integrations(resource, action)

    Enum.each(outbound_integrations, fn outbound_integration ->
      dispatch_to_outbound_integration(
        outbound_integration,
        event_id,
        resource,
        action,
        resource_id,
        occurred_at
      )
    end)

    # Notify scheduler that new events may be ready
    if outbound_integrations != [] do
      AshIntegration.EventScheduler.notify()
    end

    :ok
  end

  def perform(%Oban.Job{}), do: :ok

  # Find ALL active integrations matching resource/action.
  # Includes suspended integrations — we create events for them too (no data loss).
  defp find_matching_outbound_integrations(resource, action) do
    AshIntegration.outbound_integration_resource()
    |> Ash.Query.filter(active == true and resource == ^resource and ^action in actions)
    |> Ash.Query.load(:owner)
    |> Ash.read!(authorize?: false)
  end

  defp dispatch_to_outbound_integration(
         outbound_integration,
         event_id,
         resource,
         action,
         resource_id,
         occurred_at
       ) do
    case EventDataLoader.load_event_data(
           resource,
           resource_id,
           action,
           outbound_integration.schema_version,
           outbound_integration.owner
         ) do
      {:ok, event_data} ->
        create_event(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          occurred_at,
          event_data
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to load event data for integration #{outbound_integration.id}: #{inspect(reason)}"
        )
    end
  end

  defp create_event(
         outbound_integration,
         event_id,
         resource,
         action,
         resource_id,
         occurred_at,
         snapshot
       ) do
    # Build the event structure for Lua transform
    event_for_lua =
      AshIntegration.OutboundIntegrations.Info.build_event(%{
        id: event_id,
        resource: resource,
        action: action,
        schema_version: outbound_integration.schema_version,
        occurred_at: occurred_at,
        data: snapshot
      })

    # Run Lua transform inline — cache the result on the event
    lua_result =
      case LuaSandbox.execute(outbound_integration.transform_script, event_for_lua) do
        {:ok, :skip} ->
          :skip

        {:ok, payload} ->
          {:event, payload, nil}

        {:error, lua_error} ->
          {:event, nil, "Lua error: #{lua_error}"}
      end

    event_resource = AshIntegration.outbound_integration_event_resource()

    case lua_result do
      :skip ->
        # Create a cancelled event for audit trail — Lua intentionally skipped this
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: resource,
            action: action,
            resource_id: resource_id,
            occurred_at: parse_datetime(occurred_at),
            snapshot: snapshot,
            payload: nil,
            state: :cancelled,
            last_error: "Skipped by Lua transform",
            integration_id: outbound_integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

        :ok

      {:event, payload, last_error} ->
        event_resource
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource: resource,
            action: action,
            resource_id: resource_id,
            occurred_at: parse_datetime(occurred_at),
            snapshot: snapshot,
            payload: payload,
            state: :pending,
            last_error: last_error,
            integration_id: outbound_integration.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)
        |> case do
          {:ok, _event} ->
            :ok

          {:error, err} ->
            Logger.error(
              "Failed to create event for integration #{outbound_integration.id}: #{inspect(err)}"
            )
        end
    end
  end

  defp parse_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime
  defp parse_datetime(_), do: DateTime.utc_now()
end
