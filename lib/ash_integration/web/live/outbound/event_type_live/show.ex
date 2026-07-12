defmodule AshIntegration.Web.Outbound.EventTypeLive.Show do
  @moduledoc false
  # One event type: its declared versions, the producers (resource · action) that
  # emit it, the subscriptions consuming it (across connections), and recent facts.
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Outbound.Declare.Registry
  alias AshIntegration.Web.Outbound.DeliveryLive.Helpers, as: DeliveryHelpers
  alias AshIntegration.Web.Outbound.EventLive.Helpers, as: EventHelpers
  alias AshIntegration.Web.Outbound.Helpers

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"type" => type}, _url, socket) do
    case Map.fetch(Registry.catalog(), type) do
      {:ok, %{versions: versions, producers: producers}} ->
        {:noreply,
         socket
         |> assign(
           type: type,
           versions: versions,
           producers: Enum.uniq(producers),
           page_title: type
         )
         |> load_subscriptions(type)
         |> load_recent_events(type)}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unknown event type")
         |> push_navigate(to: path(:index))}
    end
  end

  defp load_subscriptions(socket, type) do
    actor = socket.assigns.current_user

    subscriptions =
      case AshIntegration.subscription_resource()
           |> Ash.Query.for_read(:read, %{}, actor: actor)
           |> Ash.Query.filter(event_type == ^type)
           |> Ash.Query.load([:connection, :parked_count])
           |> Ash.read(actor: actor, page: false) do
        {:ok, %{results: results}} -> results
        {:ok, results} when is_list(results) -> results
        _ -> []
      end

    assign(socket, subscriptions: subscriptions)
  end

  defp load_recent_events(socket, type) do
    actor = socket.assigns.current_user

    events =
      case AshIntegration.event_resource()
           |> Ash.Query.for_read(:index, %{}, actor: actor)
           |> Ash.Query.filter(event_type == ^type)
           |> Ash.read(actor: actor, page: [limit: 10, count: false]) do
        {:ok, %{results: results}} -> results
        {:ok, results} when is_list(results) -> results
        _ -> []
      end

    assign(socket, recent_events: events)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:event_types} />

      <div class="breadcrumbs text-sm mb-2">
        <ul>
          <li><.link navigate={path(:index)}>Event Types</.link></li>
          <li>{@type}</li>
        </ul>
      </div>

      <.page_header>
        <span class="font-mono">{@type}</span>
        <:subtitle>
          <span :for={v <- @versions} class="badge badge-sm badge-ghost mr-1">v{v}</span>
        </:subtitle>
      </.page_header>

      <div class="card card-border border-base-300 p-4 mb-6">
        <h3 class="font-semibold mb-2">Producers</h3>
        <p class="text-xs text-base-content/50 mb-3">
          The resource actions that emit this event type. Same string = same logical event.
        </p>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Source resource</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{resource, action} <- @producers}>
              <td class="font-mono text-xs">{inspect(resource)}</td>
              <td class="font-mono text-xs">{action}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3 class="font-semibold mb-2">Subscriptions ({length(@subscriptions)})</h3>
      <div :if={@subscriptions == []} class="text-sm text-base-content/50 mb-6">
        No subscriptions consume this event type yet.
      </div>
      <table :if={@subscriptions != []} class="table table-zebra mb-6">
        <thead>
          <tr>
            <th>Connection</th>
            <th>Version</th>
            <th>Status</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={sub <- @subscriptions}>
            <td class="text-sm">
              <.link
                :if={sub.connection}
                navigate={base() <> "/connections/#{sub.connection_id}"}
                class="link link-hover"
              >
                {sub.connection.name}
              </.link>
              <span :if={!sub.connection} class="text-base-content/50">—</span>
            </td>
            <td>v{sub.version}</td>
            <td>
              <div class="flex items-center gap-1">
                <.active_badge active={sub.active} />
                <DeliveryHelpers.health_badge record={sub} />
              </div>
            </td>
            <td class="text-right">
              <.link
                navigate={base() <> "/subscriptions/#{sub.id}"}
                class="btn btn-ghost btn-xs"
              >
                View
              </.link>
            </td>
          </tr>
        </tbody>
      </table>

      <h3 class="font-semibold mb-2">Recent events</h3>
      <div :if={@recent_events == []} class="text-sm text-base-content/50">
        No events captured for this type yet.
      </div>
      <table :if={@recent_events != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Key</th>
            <th>Outbox</th>
            <th>Created</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @recent_events}>
            <td class="font-mono text-xs">{event.event_key}</td>
            <td><EventHelpers.outbox_badge event={event} /></td>
            <td class="text-sm text-base-content/60">{Helpers.format_datetime(event.created_at)}</td>
            <td class="text-right">
              <.link navigate={base() <> "/events/#{event.id}"} class="btn btn-ghost btn-xs">
                View
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp path(:index), do: base() <> "/event-types"
  defp base, do: AshIntegration.Web.base_path()
end
