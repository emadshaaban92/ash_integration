defmodule AshIntegration.Web.Outbound.EventLive.All do
  @moduledoc false
  # The immutable Event browser — the transactional outbox. One row per captured
  # fact (independent of how many subscriptions it fans out to).
  # `dispatched_at IS NULL` means still in the outbox; a fact that is terminal
  # (`dispatch_terminal_reason` set — the opt-in age sweep gave up on it) is
  # **stuck** — left undispatched on purpose, blocking its lane, never auto-resolved.
  # There is no attempt ceiling. The per-subscription delivery state machine lives
  # under /deliveries.
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Web.Outbound.EventLive.Helpers, as: EventHelpers
  alias AshIntegration.Web.Outbound.Helpers

  @outbox_states ~w(in_outbox dispatched stuck)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Events", events: [], page: Helpers.empty_page())
     |> assign(event_types: Helpers.event_types(), outbox_states: @outbox_states)
     |> assign(filters: empty_filters())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(filters: parse_filters(params))
     |> load_events(Helpers.parse_int(params["offset"], 0))}
  end

  defp load_events(socket, offset) do
    actor = socket.assigns.current_user
    f = socket.assigns.filters

    query =
      AshIntegration.event_resource()
      |> Ash.Query.for_read(:index, %{}, actor: actor)
      |> apply_event_type(f.event_type)
      |> apply_outbox(f.outbox)

    page = Helpers.read_page!(query, actor: actor, page: [limit: 20, offset: offset, count: true])

    assign(socket, events: page.results, page: Helpers.page_meta(page))
  end

  defp apply_event_type(query, nil), do: query
  defp apply_event_type(query, type), do: Ash.Query.filter(query, event_type == ^type)

  defp apply_outbox(query, :in_outbox), do: Ash.Query.filter(query, is_nil(dispatched_at))
  defp apply_outbox(query, :dispatched), do: Ash.Query.filter(query, not is_nil(dispatched_at))

  defp apply_outbox(query, :stuck),
    do: Ash.Query.filter(query, is_nil(dispatched_at) and not is_nil(dispatch_terminal_reason))

  defp apply_outbox(query, _), do: query

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: path(parse_filters(params), 0))}
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, push_patch(socket, to: path(socket.assigns.filters, Helpers.parse_int(offset, 0)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:events} />

      <.page_header>
        Events
        <:subtitle>
          The immutable fact — the transactional outbox. One row per captured change.
        </:subtitle>
      </.page_header>

      <form phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <.filter_select
          name="event_type"
          label="Event type"
          prompt="All types"
          options={Enum.map(@event_types, &{&1, &1})}
          selected={@filters.event_type}
        />
        <.filter_select
          name="outbox"
          label="Outbox status"
          prompt="All"
          options={Enum.map(@outbox_states, &{&1, outbox_label(&1)})}
          selected={@filters.outbox}
        />
      </form>

      <div :if={@events == []}>
        <.empty_state title="No events match these filters" icon="hero-inbox" />
      </div>

      <table :if={@events != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Event Type</th>
            <th>Key</th>
            <th>Source</th>
            <th>Outbox</th>
            <th>Created</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @events} id={"event-#{event.id}"}>
            <td class="font-medium">
              {event.event_type} <span class="text-base-content/50">v{event.version}</span>
            </td>
            <td class="font-mono text-xs">{event.event_key}</td>
            <td class="text-sm">{event.source_resource} · {event.source_action}</td>
            <td><EventHelpers.outbox_badge event={event} /></td>
            <td class="text-sm text-base-content/60">{Helpers.format_datetime(event.created_at)}</td>
            <td class="text-right">
              <.link navigate={path(:show, event.id)} class="btn btn-ghost btn-xs">View</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <.pagination page={@page} />
    </div>
    """
  end

  defp outbox_label("in_outbox"), do: "In outbox"
  defp outbox_label("dispatched"), do: "Dispatched"
  defp outbox_label("stuck"), do: "Stuck (expired)"
  defp outbox_label(other), do: other

  defp empty_filters, do: %{event_type: nil, outbox: nil}

  defp parse_filters(params) do
    %{
      event_type: Helpers.presence(params["event_type"]),
      outbox: normalize_outbox(params["outbox"])
    }
  end

  defp normalize_outbox(state) when state in @outbox_states, do: String.to_existing_atom(state)
  defp normalize_outbox(_), do: nil

  defp path(:show, id), do: base() <> "/events/#{id}"

  defp path(filters, offset) do
    Helpers.filtered_path("/events",
      event_type: filters.event_type,
      outbox: filters.outbox && to_string(filters.outbox),
      offset: offset
    )
  end

  defp base, do: AshIntegration.Web.base_path()
end
