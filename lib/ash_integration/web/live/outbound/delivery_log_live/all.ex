defmodule AshIntegration.Web.Outbound.DeliveryLogLive.All do
  @moduledoc false
  # The per-attempt transport log — the bottom of the runtime drill-down
  # (Event → Delivery → Log). Every delivery attempt across all connections, with
  # filtering by connection, status, and event type. Deep-linkable via
  # `?subscription=<id>` and `?connection=<id>`.
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Web.Outbound.Helpers

  @statuses ~w(success failed skipped suppressed)

  # Time-window options for the `since` filter. The keys double as the deep-link
  # param carried by the dashboard's "(24h)" tiles (`?since=24h`), so the drill-down
  # lands time-boxed to exactly the window the tile counted. Ordered list (not a map)
  # so the dropdown renders shortest-window-first.
  @windows [
    {"1h", "Last hour"},
    {"24h", "Last 24 hours"},
    {"7d", "Last 7 days"}
  ]
  @window_keys Enum.map(@windows, &elem(&1, 0))

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Delivery Logs", logs: [], page: Helpers.empty_page())
     |> assign(connections: [], statuses: @statuses, event_types: Helpers.event_types())
     |> assign(windows: @windows)
     |> assign(filters: empty_filters())
     |> load_connections()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(filters: parse_filters(params))
     |> load_logs(Helpers.parse_int(params["offset"], 0))}
  end

  defp load_connections(socket),
    do: assign(socket, connections: Helpers.list_connections(socket.assigns.current_user))

  defp load_logs(socket, offset) do
    actor = socket.assigns.current_user
    f = socket.assigns.filters

    query =
      AshIntegration.delivery_log_resource()
      |> Ash.Query.for_read(:index, %{}, actor: actor)
      |> Ash.Query.load(:connection)
      # Newest-first by `id` (uuidv7) — the Log's canonical recency key: it matches
      # the `:index` action default and the health indexes, and being unique keeps
      # offset-pagination boundaries stable (equal-`created_at` rows can't duplicate
      # or skip across pages).
      |> Ash.Query.sort(id: :desc)
      |> apply_filter(:connection_id, f.connection)
      |> apply_filter(:event_type, f.event_type)
      |> apply_filter(:subscription_id, f.subscription)
      |> apply_status(f.status)
      |> apply_since(f.since)

    page = Helpers.read_page!(query, actor: actor, page: [limit: 20, offset: offset, count: true])

    assign(socket, logs: page.results, page: Helpers.page_meta(page))
  end

  defp apply_filter(query, _field, nil), do: query
  defp apply_filter(query, _field, ""), do: query

  defp apply_filter(query, :connection_id, value),
    do: Ash.Query.filter(query, connection_id == ^value)

  defp apply_filter(query, :event_type, value),
    do: Ash.Query.filter(query, event_type == ^value)

  defp apply_filter(query, :subscription_id, value),
    do: Ash.Query.filter(query, subscription_id == ^value)

  defp apply_status(query, nil), do: query
  defp apply_status(query, status), do: Ash.Query.filter(query, status == ^status)

  # Time-box to the selected window. Bounds the list to the same span the dashboard's
  # "(24h)" tiles count over, so tile → list drill-down stays consistent (the tile's
  # number and the rows it lands on describe the same window).
  defp apply_since(query, nil), do: query

  defp apply_since(query, since) do
    case window_cutoff(since) do
      nil -> query
      cutoff -> Ash.Query.filter(query, created_at >= ^cutoff)
    end
  end

  defp window_cutoff("1h"), do: DateTime.add(DateTime.utc_now(), -1, :hour)
  defp window_cutoff("24h"), do: DateTime.add(DateTime.utc_now(), -24, :hour)
  defp window_cutoff("7d"), do: DateTime.add(DateTime.utc_now(), -24 * 7, :hour)
  defp window_cutoff(_), do: nil

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: path(merge_filters(socket.assigns.filters, params), 0))}
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, push_patch(socket, to: path(socket.assigns.filters, Helpers.parse_int(offset, 0)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:logs} />

      <.page_header>
        Delivery Logs
        <:subtitle>Every delivery attempt — the per-attempt transport log.</:subtitle>
      </.page_header>

      <form phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <.filter_select
          name="connection"
          label="Connection"
          prompt="All connections"
          options={Enum.map(@connections, &{&1.id, &1.name})}
          selected={@filters.connection}
        />
        <.filter_select
          name="event_type"
          label="Event type"
          prompt="All types"
          options={Enum.map(@event_types, &{&1, &1})}
          selected={@filters.event_type}
        />
        <.filter_select
          name="status"
          label="Status"
          prompt="All statuses"
          options={Enum.map(@statuses, &{&1, Helpers.humanize(&1)})}
          selected={@filters.status}
        />
        <.filter_select
          name="since"
          label="Time window"
          prompt="All time"
          options={@windows}
          selected={@filters.since}
        />

        <.subscription_filter_badge
          :if={@filters.subscription}
          navigate={path(%{@filters | subscription: nil}, 0)}
        />
      </form>

      <div :if={@logs == []}>
        <.empty_state title="No delivery logs match these filters" icon="hero-inbox" />
      </div>

      <table :if={@logs != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Status</th>
            <th>Event Type</th>
            <th>Connection</th>
            <th>Response</th>
            <th>Duration</th>
            <th>When</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={log <- @logs} id={"log-#{log.id}"}>
            <td><.status_badge status={log.status} /></td>
            <td class="font-medium">{log.event_type}</td>
            <td class="text-sm">{log.connection && log.connection.name}</td>
            <td class="text-sm">{log.response_status || log.error_message || "—"}</td>
            <td class="text-sm">{log.duration_ms && "#{log.duration_ms} ms"}</td>
            <td class="text-sm text-base-content/60">{Helpers.format_datetime(log.created_at)}</td>
            <td class="text-right">
              <.link navigate={path(:show, log.id)} class="btn btn-ghost btn-xs">View</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <.pagination page={@page} />
    </div>
    """
  end

  defp empty_filters,
    do: %{connection: nil, status: nil, event_type: nil, subscription: nil, since: nil}

  defp parse_filters(params) do
    %{
      connection: Helpers.presence(params["connection"]),
      status: normalize_status(params["status"]),
      event_type: Helpers.presence(params["event_type"]),
      subscription: Helpers.presence(params["subscription"]),
      since: normalize_since(params["since"])
    }
  end

  defp merge_filters(current, params) do
    %{
      connection: Helpers.presence(params["connection"]),
      status: normalize_status(params["status"]),
      event_type: Helpers.presence(params["event_type"]),
      since: normalize_since(params["since"]),
      # subscription is deep-link only — not part of the filter form.
      subscription: current.subscription
    }
  end

  defp normalize_status(status) when status in @statuses, do: String.to_existing_atom(status)
  defp normalize_status(_), do: nil

  defp normalize_since(since) when since in @window_keys, do: since
  defp normalize_since(_), do: nil

  defp path(:show, id), do: base() <> "/logs/#{id}"

  defp path(filters, offset) do
    Helpers.filtered_path("/logs",
      connection: filters.connection,
      status: filters.status && to_string(filters.status),
      event_type: filters.event_type,
      subscription: filters.subscription,
      since: filters.since,
      offset: offset
    )
  end

  defp base, do: AshIntegration.Web.base_path()
end
