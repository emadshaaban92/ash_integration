defmodule AshIntegration.Web.OutboundIntegrationEventLive.Index do
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @impl true
  def mount(%{"id" => integration_id}, _session, socket) do
    actor = socket.assigns.current_user

    case Ash.get(AshIntegration.outbound_integration_resource(), integration_id, actor: actor) do
      {:ok, integration} ->
        {:ok,
         assign(socket,
           integration: integration,
           page_title: "Events — #{integration.name}",
           state_filter: nil
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Integration not found")
         |> push_navigate(to: base_path())}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    offset = parse_int(params["offset"], 0)
    state_filter = params["state"]
    {:noreply, load_events(socket, offset, state_filter)}
  end

  defp load_events(socket, offset, state_filter) do
    resource = AshIntegration.outbound_integration_event_resource()
    integration = socket.assigns.integration

    query =
      resource
      |> Ash.Query.for_read(:for_integration, %{
        integration_id: integration.id
      })

    query =
      if state_filter && state_filter != "" do
        state_atom = String.to_existing_atom(state_filter)
        Ash.Query.filter(query, state == ^state_atom)
      else
        query
      end

    actor = socket.assigns.current_user

    case Ash.read(query, actor: actor, page: [limit: 20, offset: offset, count: true]) do
      {:ok, page} ->
        assign(socket,
          events: page.results,
          state_filter: state_filter,
          page: %{offset: page.offset || 0, limit: page.limit || 20, count: page.count}
        )

      {:error, _} ->
        assign(socket,
          events: [],
          state_filter: state_filter,
          page: %{offset: 0, limit: 20, count: 0}
        )
    end
  end

  @impl true
  def handle_event("filter", %{"state" => state}, socket) do
    {:noreply, load_events(socket, 0, state)}
  end

  @impl true
  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, load_events(socket, parse_int(offset, 0), socket.assigns.state_filter)}
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val

  defp base_path, do: AshIntegration.Web.base_path()

  defp truncate_id(id) when is_binary(id), do: String.slice(id, 0, 8) <> "..."
  defp truncate_id(id), do: to_string(id)

  defp state_badge_class(:pending), do: "badge-warning"
  defp state_badge_class(:scheduled), do: "badge-info"
  defp state_badge_class(:delivered), do: "badge-success"
  defp state_badge_class(:cancelled), do: "badge-neutral"
  defp state_badge_class(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.back_link navigate={"#{base_path()}/#{@integration.id}"} label="Back to Integration" />

      <.page_header>
        Events — {@integration.name}
      </.page_header>

      <div class="mb-4">
        <form phx-change="filter" class="flex gap-2 items-center">
          <label class="text-sm font-medium">Filter by state:</label>
          <select name="state" class="select select-bordered select-sm">
            <option value="">All</option>
            <option value="pending" selected={@state_filter == "pending"}>Pending</option>
            <option value="scheduled" selected={@state_filter == "scheduled"}>Scheduled</option>
            <option value="delivered" selected={@state_filter == "delivered"}>Delivered</option>
            <option value="cancelled" selected={@state_filter == "cancelled"}>Cancelled</option>
          </select>
        </form>
      </div>

      <div :if={@events == []}>
        <.empty_state title="No events found" icon="hero-bolt" />
      </div>

      <div :if={@events != []} class="overflow-x-auto">
        <table class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>Event ID</th>
              <th>Resource</th>
              <th>Action</th>
              <th>Resource ID</th>
              <th>State</th>
              <th>Attempts</th>
              <th>Last Error</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @events} id={"event-#{event.id}"}>
              <td>
                <.link
                  navigate={"#{base_path()}/events/#{event.id}"}
                  class="link link-primary font-mono text-sm"
                >
                  {truncate_id(event.id)}
                </.link>
              </td>
              <td><.resource_badge value={event.resource} /></td>
              <td class="text-sm">{humanize(event.action)}</td>
              <td class="font-mono text-sm">{truncate_id(event.resource_id)}</td>
              <td>
                <span class={["badge badge-sm", state_badge_class(event.state)]}>
                  {event.state}
                </span>
              </td>
              <td>
                <span class={[
                  "text-sm",
                  event.attempts > 0 && event.state != :delivered && "text-error font-bold"
                ]}>
                  {event.attempts}
                </span>
              </td>
              <td class="text-sm text-error max-w-xs truncate">
                {event.last_error}
              </td>
              <td class="text-sm text-base-content/60">
                {Helpers.format_datetime(event.created_at, :long)}
              </td>
            </tr>
          </tbody>
        </table>
        <.pagination page={@page} />
      </div>
    </div>
    """
  end
end
