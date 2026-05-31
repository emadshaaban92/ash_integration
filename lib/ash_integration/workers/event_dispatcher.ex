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
          {:ok, event} ->
            coalesce_superseded_pending(outbound_integration, event)
            :ok

          {:error, err} ->
            Logger.error(
              "Failed to create event for integration #{outbound_integration.id}: #{inspect(err)}"
            )
        end
    end
  end

  # Log-compaction / conflation: by default an integration only needs the LATEST
  # state per resource, so among the pending events for a (integration, resource_id)
  # we keep only the newest (by occurred_at, then id) and cancel the rest. This bounds
  # the pending backlog to ~one event per resource at all times (even while suspended,
  # since the dispatcher keeps creating events), so unsuspending never has to drain a
  # huge backlog of intermediate updates.
  #
  # We compute "newest" from the full pending set (not "the event just created") so
  # out-of-order dispatch can't leave a stale event as the survivor.
  #
  # Opt out per integration with `notify_on_every_change: true` to get one delivery per
  # change (no coalescing). The payload is snapshotted here at DISPATCH time (the transform
  # runs and caches it now) — as early as practical, so intermediate states are preserved in
  # the common case (capturing at the exact change instant would mean snapshotting inside
  # every source write, which is too costly). Skipped entirely if ANY pending
  # event for the resource has a nil payload (Lua failed) — that chain is blocked awaiting
  # :reprocess, and we must not strand it by cancelling its deliverable siblings.
  defp coalesce_superseded_pending(%{notify_on_every_change: true}, _event), do: :ok

  defp coalesce_superseded_pending(outbound_integration, event) do
    event_resource = AshIntegration.outbound_integration_event_resource()

    pending =
      event_resource
      |> Ash.Query.filter(
        integration_id == ^outbound_integration.id and
          resource_id == ^event.resource_id and
          state == :pending
      )
      |> Ash.read!(authorize?: false)

    cond do
      Enum.any?(pending, &is_nil(&1.payload)) ->
        :ok

      true ->
        superseded =
          pending
          |> Enum.sort_by(&{&1.occurred_at, &1.id}, :desc)
          |> Enum.drop(1)

        cancel_superseded(superseded, outbound_integration, event)
    end
  end

  defp cancel_superseded([], _outbound_integration, _event), do: :ok

  defp cancel_superseded(superseded, outbound_integration, event) do
    for stale <- superseded do
      stale
      |> Ash.Changeset.for_update(
        :cancel,
        %{last_error: "Superseded by a newer update (coalesced)"},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)
    end

    count = length(superseded)

    Logger.info(
      "Coalesced #{count} superseded pending event(s) for integration " <>
        "#{outbound_integration.id} (resource #{event.resource}/#{event.resource_id})"
    )

    :telemetry.execute(
      [:ash_integration, :coalesce, :events_dropped],
      %{count: count},
      %{
        integration_id: outbound_integration.id,
        resource: event.resource,
        resource_id: event.resource_id
      }
    )

    :ok
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
