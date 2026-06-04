defmodule AshIntegration.Web.Outbound.ConnectionLive.Index do
  @moduledoc false
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.Outbound.Helpers
  alias AshIntegration.Web.Outbound.ConnectionLive.FormComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       connections: [],
       can_create: false,
       perms: %{},
       page: %{offset: 0, limit: 20, count: 0}
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New Connection", connection: nil)
    |> load_connections(0)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Ash.get(AshIntegration.connection_resource(), id, actor: socket.assigns.current_user) do
      {:ok, connection} ->
        socket
        |> assign(page_title: "Edit #{connection.name}", connection: connection)
        |> load_connections(0)

      {:error, _} ->
        socket
        |> put_flash(:error, "Connection not found")
        |> push_navigate(to: path(:index))
    end
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(page_title: "Connections")
    |> load_connections(Helpers.parse_int(params["offset"], 0))
  end

  defp load_connections(socket, offset) do
    actor = socket.assigns.current_user

    case AshIntegration.connection_resource()
         |> Ash.Query.for_read(:index, %{}, actor: actor)
         |> Ash.Query.load(:owner)
         |> Ash.read(actor: actor, page: [limit: 20, offset: offset, count: true]) do
      {:ok, page} ->
        assign(socket,
          connections: page.results,
          can_create: Helpers.can?({AshIntegration.connection_resource(), :create}, actor),
          perms: row_perms(page.results, actor),
          page: %{offset: page.offset || 0, limit: page.limit || 20, count: page.count}
        )

      {:error, _} ->
        assign(socket, connections: [], page: %{offset: 0, limit: 20, count: 0})
    end
  end

  # Per-row edit/destroy permission, resolved once per load (not per render).
  defp row_perms(records, actor) do
    Map.new(records, fn r ->
      {r.id,
       %{update: Helpers.can?({r, :update}, actor), destroy: Helpers.can?({r, :destroy}, actor)}}
    end)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    with {:ok, record} <- Ash.get(AshIntegration.connection_resource(), id, actor: actor),
         :ok <- Ash.destroy(record, actor: actor) do
      {:noreply, socket |> put_flash(:info, "Connection deleted") |> load_connections(0)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete connection")}
    end
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, load_connections(socket, Helpers.parse_int(offset, 0))}
  end

  @impl true
  def handle_info({FormComponent, {:saved, _record}}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:connections} />

      <.page_header>
        Connections
        <:subtitle>Reusable transport + auth configs (the ordering domain).</:subtitle>
        <:actions>
          <.link :if={@can_create} navigate={path(:new)} class="btn btn-primary btn-sm">
            <.icon name="hero-plus-mini" /> New Connection
          </.link>
        </:actions>
      </.page_header>

      <div :if={@connections == []}>
        <.empty_state title="No connections yet">
          <:actions>
            <.link :if={@can_create} navigate={path(:new)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus-mini" /> Create your first connection
            </.link>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@connections != []}>
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Transport</th>
              <th>Owner</th>
              <th>Status</th>
              <th>Failures</th>
              <th>Created</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={connection <- @connections} id={"connection-#{connection.id}"}>
              <td>
                <.link navigate={path(:show, connection.id)} class="link link-hover font-medium">
                  {connection.name}
                </.link>
              </td>
              <td>{humanize(connection.transport_config.type)}</td>
              <td class="text-sm">{Helpers.owner_name(connection)}</td>
              <td><.active_badge active={connection.active} /></td>
              <td>
                <span class={[
                  "badge badge-sm",
                  if(connection.consecutive_failures > 0, do: "badge-warning", else: "badge-ghost")
                ]}>
                  {connection.consecutive_failures}
                </span>
              </td>
              <td class="text-sm text-base-content/60">
                {Helpers.format_datetime(connection.created_at)}
              </td>
              <td>
                <div class="dropdown dropdown-end">
                  <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
                    <.icon name="hero-ellipsis-vertical-mini" />
                  </div>
                  <ul
                    tabindex="0"
                    class="dropdown-content z-10 menu p-2 shadow bg-base-200 rounded-box w-40"
                  >
                    <li><.link navigate={path(:show, connection.id)}>View</.link></li>
                    <li :if={@perms[connection.id][:update]}>
                      <.link patch={path(:edit, connection.id)}>Edit</.link>
                    </li>
                    <li :if={@perms[connection.id][:destroy]}>
                      <button
                        phx-click="delete"
                        phx-value-id={connection.id}
                        data-confirm="Delete this connection and all its subscriptions?"
                      >
                        Delete
                      </button>
                    </li>
                  </ul>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
        <.pagination page={@page} />
      </div>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="connection-modal"
        show
        on_cancel={JS.navigate(path(:index))}
      >
        <h3 class="text-lg font-bold mb-4">
          {if @live_action == :new, do: "New Connection", else: "Edit Connection"}
        </h3>
        <.live_component
          module={FormComponent}
          id="connection-form"
          action={@live_action}
          connection={assigns[:connection]}
          actor={@current_user}
          navigate={path(:index)}
        />
      </.modal>
    </div>
    """
  end

  defp path(:index), do: base() <> "/connections"
  defp path(:new), do: base() <> "/connections/new"
  defp path(:edit, id), do: base() <> "/connections/edit/#{id}"
  defp path(:show, id), do: base() <> "/connections/#{id}"

  defp base, do: AshIntegration.Web.base_path()
end
