defmodule AshIntegration.Workers.EventDispatcher do
  use Oban.Worker,
    queue: :integration_dispatch,
    max_attempts: 3,
    unique: [keys: [:event_id]]

  require Ash.Query
  require Logger

  alias AshIntegration.EventDataLoader

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

    :ok
  end

  def perform(%Oban.Job{}), do: :ok

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
    occurred_dt = parse_datetime(occurred_at)

    case EventDataLoader.load_event(
           resource,
           resource_id,
           action,
           outbound_integration.schema_version,
           occurred_dt,
           outbound_integration.owner
         ) do
      {:ok, event_data} ->
        %{
          event_id: event_id,
          resource: resource,
          action: action,
          outbound_integration_id: outbound_integration.id,
          resource_id: resource_id,
          snapshot: event_data
        }
        |> AshIntegration.Workers.OutboundDelivery.new()
        |> Oban.insert()

      {:error, reason} ->
        Logger.warning(
          "Failed to load event data for outbound integration #{outbound_integration.id}: #{inspect(reason)}"
        )
    end
  end

  defp parse_datetime(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _} ->
        datetime

      {:error, reason} ->
        raise ArgumentError,
              "invalid occurred_at datetime #{inspect(dt)}: #{inspect(reason)}"
    end
  end

  defp parse_datetime(other) do
    raise ArgumentError,
          "expected occurred_at to be an ISO 8601 string, got: #{inspect(other)}"
  end
end
