defmodule AshIntegration.Web.Outbound.DeliveryLive.All do
  @moduledoc false
  # The EventDelivery browser: the per-subscription delivery state machine
  # (pending/parked/scheduled/failed/delivered/suppressed/cancelled), across all
  # connections, with filtering by connection, event type, and state. This is the middle layer of
  # the model — one row per (event, subscription). The immutable fact lives under
  # /events; the per-attempt transport log under /logs.
  #
  # Deep-linkable via `?subscription=<id>` (from a subscription) and
  # `?connection=<id>` (from a connection). When a single connection is in scope
  # and it has parked deliveries, a bulk "reprocess parked" action is offered.
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Reprocessor
  alias AshIntegration.Web.Outbound.DeliveryLive.Helpers, as: DeliveryHelpers
  alias AshIntegration.Web.Outbound.Helpers

  @states ~w(pending parked scheduled failed delivered suppressed cancelled)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Deliveries",
       deliveries: [],
       page: Helpers.empty_page(),
       parked_count: 0,
       can_reprocess: false
     )
     |> assign(connections: [], event_types: Helpers.event_types(), states: @states)
     |> assign(filters: empty_filters())
     |> load_connections()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filters = parse_filters(params)

    {:noreply,
     socket
     |> assign(filters: filters)
     |> load_deliveries(Helpers.parse_int(params["offset"], 0))}
  end

  defp load_connections(socket),
    do: assign(socket, connections: Helpers.list_connections(socket.assigns.current_user))

  defp load_deliveries(socket, offset) do
    actor = socket.assigns.current_user
    f = socket.assigns.filters

    query =
      AshIntegration.event_delivery_resource()
      |> Ash.Query.for_read(:index, %{}, actor: actor)
      |> Ash.Query.load(:connection)
      |> apply_filter(:connection_id, f.connection)
      |> apply_filter(:event_type, f.event_type)
      |> apply_filter(:subscription_id, f.subscription)
      |> apply_state(f.state)

    page = Helpers.read_page!(query, actor: actor, page: [limit: 20, offset: offset, count: true])

    socket
    |> assign(deliveries: page.results, page: Helpers.page_meta(page))
    |> assign(parked_count: parked_count(f.connection, actor))
    |> assign(
      can_reprocess: Helpers.can?({AshIntegration.event_delivery_resource(), :reprocess}, actor)
    )
  end

  # Parked count is only meaningful (and the bulk reprocess only safe) when a
  # single connection is in scope — Reprocessor works per connection.
  defp parked_count(nil, _actor), do: 0

  # No-bang: a host policy could forbid the read for this actor; degrade to 0
  # (hiding the bulk action) rather than crashing the page.
  defp parked_count(connection_id, actor) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(connection_id == ^connection_id and state == :parked)
    |> Ash.count(actor: actor)
    |> case do
      {:ok, n} -> n
      {:error, _} -> 0
    end
  end

  defp apply_filter(query, _field, nil), do: query
  defp apply_filter(query, _field, ""), do: query

  defp apply_filter(query, :connection_id, value),
    do: Ash.Query.filter(query, connection_id == ^value)

  defp apply_filter(query, :event_type, value),
    do: Ash.Query.filter(query, event_type == ^value)

  defp apply_filter(query, :subscription_id, value),
    do: Ash.Query.filter(query, subscription_id == ^value)

  defp apply_state(query, nil), do: query
  defp apply_state(query, state), do: Ash.Query.filter(query, state == ^state)

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: path(merge_filters(socket.assigns.filters, params), 0))}
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, push_patch(socket, to: path(socket.assigns.filters, Helpers.parse_int(offset, 0)))}
  end

  def handle_event("reprocess-parked", _params, socket) do
    case socket.assigns.filters.connection do
      # No single connection is in scope — there is nothing to bulk-reprocess.
      nil -> {:noreply, socket}
      connection_id -> {:noreply, reprocess_parked(socket, connection_id)}
    end
  end

  # Bulk reprocess reads+mutates ALL of a connection's parked deliveries under
  # system authority (`authorize?: false` in the Reprocessor). LiveView events are
  # client-triggerable even when the button is hidden, so this server path is the
  # only real gate. Fail closed in two independent ways before touching anything:
  #
  #   1. Resolve the connection *as the actor* — if they can't even READ it (nil /
  #      error), they have no business re-triggering its deliveries. This binds the
  #      URL-supplied `connection_id` to something the actor is actually allowed to
  #      see, instead of trusting the filter param.
  #   2. Run the STRICT reprocess gate (`maybe_is: false`), so a record-scoped
  #      (`:maybe`) host policy denies rather than grants.
  defp reprocess_parked(socket, connection_id) do
    actor = socket.assigns.current_user

    with {:ok, _connection} <-
           Ash.get(AshIntegration.connection_resource(), connection_id, actor: actor),
         true <-
           Helpers.can_strict?({AshIntegration.event_delivery_resource(), :reprocess}, actor) do
      %{reprocessed: ok, failed: failed} =
        Reprocessor.reprocess_parked_for_connection(connection_id)

      msg =
        "Reprocessed #{ok} parked delivery(ies)" <>
          if(failed > 0, do: ", #{failed} still failing", else: "")

      socket |> put_flash(:info, msg) |> load_deliveries(socket.assigns.page.offset)
    else
      _ -> put_flash(socket, :error, "Not authorized to reprocess deliveries")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:deliveries} />

      <.page_header>
        Deliveries
        <:subtitle>
          The per-subscription delivery state machine. One row per (event, subscription).
        </:subtitle>
        <:actions>
          <button
            :if={@parked_count > 0 and @can_reprocess}
            class="btn btn-warning btn-sm"
            phx-click="reprocess-parked"
            data-confirm={"Reprocess all #{@parked_count} parked delivery(ies) for this connection?"}
          >
            <.icon name="hero-arrow-path-mini" /> Reprocess {@parked_count} parked
          </button>
        </:actions>
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
          name="state"
          label="State"
          prompt="All states"
          options={Enum.map(@states, &{&1, Helpers.humanize(&1)})}
          selected={@filters.state}
        />

        <.subscription_filter_badge
          :if={@filters.subscription}
          navigate={path(%{@filters | subscription: nil}, 0)}
        />
      </form>

      <div :if={@deliveries == []}>
        <.empty_state title="No deliveries match these filters" icon="hero-inbox" />
      </div>

      <table :if={@deliveries != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Event Type</th>
            <th>Connection</th>
            <th>Key</th>
            <th>State</th>
            <th>Attempts</th>
            <th>Created</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={delivery <- @deliveries} id={"delivery-#{delivery.id}"}>
            <td class="font-medium">
              {delivery.event_type} <span class="text-base-content/50">v{delivery.version}</span>
            </td>
            <td class="text-sm">{delivery.connection && delivery.connection.name}</td>
            <td class="font-mono text-xs">{delivery.event_key}</td>
            <td><DeliveryHelpers.state_badge delivery={delivery} /></td>
            <td>{delivery.attempts}</td>
            <td class="text-sm text-base-content/60">
              {Helpers.format_datetime(delivery.created_at)}
            </td>
            <td class="text-right">
              <.link navigate={path(:show, delivery.id)} class="btn btn-ghost btn-xs">View</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <.pagination page={@page} />
    </div>
    """
  end

  defp empty_filters, do: %{connection: nil, event_type: nil, state: nil, subscription: nil}

  defp parse_filters(params) do
    %{
      connection: Helpers.presence(params["connection"]),
      event_type: Helpers.presence(params["event_type"]),
      state: normalize_state(params["state"]),
      subscription: Helpers.presence(params["subscription"])
    }
  end

  defp merge_filters(current, params) do
    %{
      connection: Helpers.presence(params["connection"]),
      event_type: Helpers.presence(params["event_type"]),
      state: normalize_state(params["state"]),
      # subscription is deep-link only — not part of the filter form.
      subscription: current.subscription
    }
  end

  defp normalize_state(state) when state in @states, do: String.to_existing_atom(state)
  defp normalize_state(_), do: nil

  defp path(:show, id), do: base() <> "/deliveries/#{id}"

  defp path(filters, offset) do
    Helpers.filtered_path("/deliveries",
      connection: filters.connection,
      event_type: filters.event_type,
      state: filters.state && to_string(filters.state),
      subscription: filters.subscription,
      offset: offset
    )
  end

  defp base, do: AshIntegration.Web.base_path()
end
