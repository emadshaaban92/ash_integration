defmodule AshIntegration.Web.OutboundIntegrationEventLive.Show do
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @impl true
  def mount(%{"event_id" => event_id}, _session, socket) do
    actor = socket.assigns.current_user
    event_resource = AshIntegration.outbound_integration_event_resource()

    case Ash.get(event_resource, event_id,
           actor: actor,
           load: [:outbound_integration, :delivery_logs]
         ) do
      {:ok, event} ->
        {:ok,
         assign(socket,
           event: event,
           page_title: "Event #{String.slice(event_id, 0, 8)}..."
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found")
         |> push_navigate(to: base_path())}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event

    case event
         |> Ash.Changeset.for_update(:cancel, %{})
         |> Ash.update(actor: actor) do
      {:ok, updated} ->
        updated = Ash.load!(updated, [:outbound_integration, :delivery_logs], actor: actor)

        {:noreply,
         socket
         |> assign(event: updated)
         |> put_flash(:info, "Event cancelled")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel event")}
    end
  end

  @impl true
  def handle_event("reprocess", _params, socket) do
    actor = socket.assigns.current_user
    event = socket.assigns.event
    integration = event.outbound_integration

    # Re-run Lua inline
    event_for_lua =
      AshIntegration.OutboundIntegrations.Info.build_event(%{
        id: event.id,
        resource: event.resource,
        action: event.action,
        schema_version: integration.schema_version,
        occurred_at: event.occurred_at,
        data: event.snapshot
      })

    {payload, last_error} =
      case AshIntegration.LuaSandbox.execute(integration.transform_script, event_for_lua) do
        {:ok, :skip} -> {nil, "Lua returned skip"}
        {:ok, payload} -> {payload, nil}
        {:error, error} -> {nil, "Lua error: #{error}"}
      end

    case event
         |> Ash.Changeset.for_update(
           :reprocess,
           %{payload: payload, last_error: last_error}
         )
         |> Ash.update(actor: actor) do
      {:ok, updated} ->
        updated = Ash.load!(updated, [:outbound_integration, :delivery_logs], actor: actor)
        AshIntegration.EventScheduler.notify()

        {:noreply,
         socket
         |> assign(event: updated)
         |> put_flash(:info, "Event reprocessed")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reprocess event")}
    end
  end

  defp base_path, do: AshIntegration.Web.base_path()

  defp state_badge_class(:pending), do: "badge-warning"
  defp state_badge_class(:scheduled), do: "badge-info"
  defp state_badge_class(:delivered), do: "badge-success"
  defp state_badge_class(:cancelled), do: "badge-neutral"
  defp state_badge_class(_), do: "badge-ghost"

  defp format_json(nil), do: "—"

  defp format_json(map) when is_map(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(map)
    end
  end

  defp format_json(val), do: inspect(val)

  defp can_cancel?(event), do: event.state in [:pending, :scheduled]
  defp can_reprocess?(event), do: event.state == :pending

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.back_link
        navigate={"#{base_path()}/#{@event.outbound_integration_id}/events"}
        label="Back to Events"
      />

      <.page_header>
        Event {String.slice(to_string(@event.id), 0, 8)}...
        <:actions>
          <button
            :if={can_reprocess?(@event)}
            phx-click="reprocess"
            data-confirm="Re-run Lua transform and move to pending?"
            class="btn btn-sm btn-warning"
          >
            Reprocess
          </button>
          <button
            :if={can_cancel?(@event)}
            phx-click="cancel"
            data-confirm="Cancel this event? This cannot be undone."
            class="btn btn-sm btn-error"
          >
            Cancel
          </button>
        </:actions>
      </.page_header>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h3 class="card-title text-base">Details</h3>
            <dl class="grid grid-cols-2 gap-2 text-sm">
              <dt class="text-base-content/60">ID</dt>
              <dd class="font-mono break-all">{@event.id}</dd>

              <dt class="text-base-content/60">Integration</dt>
              <dd>
                <.link
                  navigate={"#{base_path()}/#{@event.outbound_integration_id}"}
                  class="link link-primary"
                >
                  {@event.outbound_integration.name}
                </.link>
              </dd>

              <dt class="text-base-content/60">State</dt>
              <dd>
                <span class={["badge", state_badge_class(@event.state)]}>
                  {@event.state}
                </span>
              </dd>

              <dt class="text-base-content/60">Resource</dt>
              <dd>{@event.resource}</dd>

              <dt class="text-base-content/60">Action</dt>
              <dd>{@event.action}</dd>

              <dt class="text-base-content/60">Resource ID</dt>
              <dd class="font-mono break-all">{@event.resource_id}</dd>

              <dt class="text-base-content/60">Attempts</dt>
              <dd class={@event.attempts > 0 && @event.state != :delivered && "text-error font-bold"}>
                {@event.attempts}
              </dd>

              <dt class="text-base-content/60">Occurred At</dt>
              <dd>{Helpers.format_datetime(@event.occurred_at, :long)}</dd>

              <dt class="text-base-content/60">Created At</dt>
              <dd>{Helpers.format_datetime(@event.created_at, :long)}</dd>

              <dt class="text-base-content/60">Updated At</dt>
              <dd>{Helpers.format_datetime(@event.updated_at, :long)}</dd>
            </dl>
          </div>
        </div>

        <div :if={@event.last_error} class="card bg-base-100 shadow">
          <div class="card-body">
            <h3 class="card-title text-base text-error">Last Error</h3>
            <pre class="text-sm bg-base-200 p-3 rounded overflow-x-auto whitespace-pre-wrap">{@event.last_error}</pre>
          </div>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h3 class="card-title text-base">Snapshot</h3>
            <pre class="text-sm bg-base-200 p-3 rounded overflow-x-auto max-h-96">{format_json(@event.snapshot)}</pre>
          </div>
        </div>

        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h3 class="card-title text-base">Payload</h3>
            <pre class="text-sm bg-base-200 p-3 rounded overflow-x-auto max-h-96">{format_json(@event.payload)}</pre>
          </div>
        </div>

        <div :if={@event.delivery_metadata} class="card bg-base-100 shadow">
          <div class="card-body">
            <h3 class="card-title text-base">Delivery Metadata</h3>
            <pre class="text-sm bg-base-200 p-3 rounded overflow-x-auto max-h-96">{format_json(@event.delivery_metadata)}</pre>
          </div>
        </div>
      </div>

      <div :if={@event.delivery_logs != []} class="mt-6">
        <h3 class="text-lg font-semibold mb-3">Delivery Logs</h3>
        <div class="overflow-x-auto">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th>Status</th>
                <th>HTTP Status</th>
                <th>Duration</th>
                <th>Error</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={log <- @event.delivery_logs} id={"log-#{log.id}"}>
                <td><.status_badge status={log.status} /></td>
                <td>
                  <span :if={log.response_status} class="badge badge-sm">
                    {log.response_status}
                  </span>
                  <span :if={is_nil(log.response_status)} class="text-base-content/50">—</span>
                </td>
                <td class="text-sm">
                  <span :if={log.duration_ms}>{log.duration_ms}ms</span>
                  <span :if={is_nil(log.duration_ms)} class="text-base-content/50">—</span>
                </td>
                <td class="text-sm text-error max-w-xs truncate">{log.error_message}</td>
                <td class="text-sm text-base-content/60">
                  {Helpers.format_datetime(log.created_at, :long)}
                </td>
                <td>
                  <.link
                    navigate={"#{base_path()}/logs/#{log.id}"}
                    class="btn btn-ghost btn-xs"
                  >
                    View
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
