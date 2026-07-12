defmodule AshIntegration.Web.Outbound.SubscriptionLive.Index do
  @moduledoc false
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Web.Outbound.DeliveryLive.Helpers, as: DeliveryHelpers
  alias AshIntegration.Web.Outbound.Helpers
  alias AshIntegration.Web.Outbound.SubscriptionLive.FormComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       subscriptions: [],
       connections: [],
       can_create: false,
       perms: %{},
       prefill_event_type: nil,
       filters: %{suspended: nil},
       page: %{offset: 0, limit: 20, count: 0}
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(page_title: "Subscriptions")
    |> assign(filters: %{suspended: normalize_suspended(params["suspended"])})
    |> load_subscriptions(Helpers.parse_int(params["offset"], 0))
  end

  defp apply_action(socket, :new, params) do
    socket
    |> assign(page_title: "New Subscription")
    |> assign(prefill_event_type: params["event_type"])
    |> load_subscriptions(0)
    |> load_connections()
  end

  defp load_subscriptions(socket, offset) do
    actor = socket.assigns.current_user

    page =
      AshIntegration.subscription_resource()
      |> Ash.Query.load([:connection, :last_delivered_at, :parked_count, :oldest_parked_at])
      |> apply_suspended(socket.assigns.filters.suspended)
      |> Helpers.read_page!(actor: actor, page: [limit: 20, offset: offset, count: true])

    assign(socket,
      subscriptions: page.results,
      can_create: Helpers.can?({AshIntegration.subscription_resource(), :create}, actor),
      perms: row_perms(page.results, actor),
      page: Helpers.page_meta(page)
    )
  end

  # Per-row edit/destroy permission, resolved once per load (not per render).
  defp row_perms(records, actor) do
    Map.new(records, fn r ->
      {r.id,
       %{update: Helpers.can?({r, :update}, actor), destroy: Helpers.can?({r, :destroy}, actor)}}
    end)
  end

  defp load_connections(socket) do
    actor = socket.assigns.current_user

    # The `:index` action requires pagination, so read a (large) first page rather
    # than `page: false` (which raises PaginationRequired and would silently leave
    # the connection picker empty).
    connections =
      case AshIntegration.connection_resource()
           |> Ash.Query.for_read(:index, %{}, actor: actor)
           |> Ash.read(actor: actor, page: [limit: 1000]) do
        {:ok, %{results: results}} -> results
        {:ok, results} when is_list(results) -> results
        _ -> []
      end

    assign(socket, connections: connections)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    with {:ok, record} <- Ash.get(AshIntegration.subscription_resource(), id, actor: actor),
         :ok <- Ash.destroy(record, actor: actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Subscription deleted")
       |> load_subscriptions(socket.assigns.page.offset)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete subscription")}
    end
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, load_subscriptions(socket, Helpers.parse_int(offset, 0))}
  end

  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: path(:index, normalize_suspended(params["suspended"])))}
  end

  defp apply_suspended(query, nil), do: query
  defp apply_suspended(query, value), do: Ash.Query.filter(query, suspended == ^value)

  defp normalize_suspended("true"), do: true
  defp normalize_suspended("false"), do: false
  defp normalize_suspended(_), do: nil

  @impl true
  def handle_info({FormComponent, {:saved, _record}}, socket) do
    {:noreply, socket |> load_subscriptions(0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:subscriptions} />

      <.page_header>
        Subscriptions
        <:subtitle>Event routes — what to watch and how to transform + deliver it.</:subtitle>
        <:actions>
          <.link :if={@can_create} navigate={path(:new)} class="btn btn-primary btn-sm">
            <.icon name="hero-plus-mini" /> New Subscription
          </.link>
        </:actions>
      </.page_header>

      <form phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <.filter_select
          name="suspended"
          label="Health"
          prompt="All subscriptions"
          options={[{"true", "Suspended (failing)"}, {"false", "Healthy"}]}
          selected={@filters.suspended}
        />
      </form>

      <div :if={@subscriptions == [] and @filters.suspended != nil}>
        <.empty_state title="No subscriptions match this filter" icon="hero-inbox">
          <:actions>
            <.link navigate={path(:index, nil)} class="btn btn-ghost btn-sm">Clear filter</.link>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@subscriptions == [] and @filters.suspended == nil}>
        <.empty_state title="No subscriptions yet — define which events to watch and how to deliver them.">
          <:actions>
            <.link :if={@can_create} navigate={path(:new)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus-mini" /> Create your first subscription
            </.link>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@subscriptions != []}>
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Event Type</th>
              <th>Version</th>
              <th>Connection</th>
              <th>Status</th>
              <th>Failures</th>
              <th>Last delivery</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={sub <- @subscriptions} id={"subscription-#{sub.id}"}>
              <td class="font-medium">
                <.link navigate={path(:show, sub.id)} class="link link-hover">
                  {sub.event_type}
                </.link>
              </td>
              <td>V{sub.version}</td>
              <td>
                <.link
                  navigate={path(:connection, sub.connection_id)}
                  class="link link-hover text-sm"
                >
                  {sub.connection && sub.connection.name}
                </.link>
              </td>
              <td>
                <div class="flex items-center gap-1">
                  <.active_badge active={sub.active} />
                  <DeliveryHelpers.health_badge record={sub} />
                </div>
              </td>
              <td>
                <span class={[
                  "badge badge-sm",
                  if(sub.suspended, do: "badge-error", else: "badge-ghost")
                ]}>
                  {if sub.suspended, do: "suspended", else: "ok"}
                </span>
              </td>
              <td class="text-sm text-base-content/60">
                {Helpers.format_datetime(sub.last_delivered_at)}
              </td>
              <td>
                <div class="flex gap-2 justify-end">
                  <.link navigate={path(:show, sub.id)} class="btn btn-ghost btn-xs">View</.link>
                  <.link
                    :if={@perms[sub.id][:update]}
                    navigate={path(:edit, sub.id)}
                    class="btn btn-ghost btn-xs"
                  >
                    Edit
                  </.link>
                  <button
                    :if={@perms[sub.id][:destroy]}
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="delete"
                    phx-value-id={sub.id}
                    data-confirm="Delete this subscription?"
                  >
                    Delete
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
        <.pagination page={@page} />
      </div>

      <.modal
        :if={@live_action == :new}
        id="subscription-modal"
        show
        on_cancel={JS.navigate(path(:index))}
      >
        <h3 class="text-lg font-bold mb-4">New Subscription</h3>
        <div :if={@connections == []} class="text-sm text-base-content/60 mb-4">
          No connections yet.
          <.link navigate={path(:new_connection)} class="link">Create a connection first</.link>
          before adding a subscription.
        </div>
        <.live_component
          :if={@connections != []}
          module={FormComponent}
          id="subscription-form"
          action={:new_subscription}
          connections={@connections}
          connection={nil}
          subscription={nil}
          prefill_event_type={@prefill_event_type}
          actor={@current_user}
          navigate={path(:index)}
        />
      </.modal>
    </div>
    """
  end

  defp path(:index), do: base() <> "/subscriptions"
  defp path(:new), do: base() <> "/subscriptions/new"
  defp path(:new_connection), do: base() <> "/connections/new"

  defp path(:index, suspended),
    do: Helpers.filtered_path("/subscriptions", suspended: suspended && to_string(suspended))

  defp path(:connection, id), do: base() <> "/connections/#{id}"
  defp path(:show, id), do: base() <> "/subscriptions/#{id}"
  defp path(:edit, id), do: base() <> "/subscriptions/#{id}/edit"

  defp base, do: AshIntegration.Web.base_path()
end
