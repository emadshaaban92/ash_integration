defmodule AshIntegration.Web.OutboundIntegrationLive.Index do
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.OutboundIntegrationLive.{Helpers, FormComponent}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Outbound Integrations",
       integrations: [],
       page: %{offset: 0, limit: 20, count: 0}
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New Outbound Integration", integration: nil)
    |> load_integrations(0)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    case Ash.get(resource, id, actor: actor) do
      {:ok, integration} ->
        socket
        |> assign(page_title: "Edit #{integration.name}", integration: integration)
        |> load_integrations(0)

      {:error, _} ->
        socket
        |> put_flash(:error, "Integration not found")
        |> push_navigate(to: path(:index))
    end
  end

  defp apply_action(socket, :index, params) do
    offset = Helpers.parse_int(params["offset"], 0)

    socket
    |> assign(page_title: "Outbound Integrations")
    |> load_integrations(offset)
  end

  defp load_integrations(socket, offset) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    case resource
         |> Ash.Query.for_read(:index, %{}, actor: actor)
         |> Ash.Query.load(:owner)
         |> Ash.read(actor: actor, page: [limit: 20, offset: offset, count: true]) do
      {:ok, page} ->
        assign(socket,
          integrations: page.results,
          page: %{
            offset: page.offset || 0,
            limit: page.limit || 20,
            count: page.count
          }
        )

      {:error, _} ->
        assign(socket, integrations: [], page: %{offset: 0, limit: 20, count: 0})
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    with {:ok, record} <- Ash.get(resource, id, actor: actor),
         :ok <- Ash.destroy(record, actor: actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Integration deleted")
       |> load_integrations(0)}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete integration")}
    end
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, load_integrations(socket, Helpers.parse_int(offset, 0))}
  end

  @impl true
  def handle_info({FormComponent, {:saved, _record}}, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.page_header>
        Outbound Integrations
        <:actions>
          <.link navigate={path(:new)} class="btn btn-primary btn-sm">
            <.icon name="hero-plus-mini" /> New Integration
          </.link>
          <.link navigate={path(:logs)} class="btn btn-ghost btn-sm">
            <.icon name="hero-document-text-mini" /> Delivery Logs
          </.link>
        </:actions>
      </.page_header>

      <div :if={@integrations == []}>
        <.empty_state title="No outbound integrations yet">
          <:actions>
            <.link navigate={path(:new)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus-mini" /> Create your first integration
            </.link>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@integrations != []}>
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Resource</th>
              <th>Actions</th>
              <th>Version</th>
              <th>Transport</th>
              <th>Owner</th>
              <th>Status</th>
              <th>Failures</th>
              <th>Created</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={integration <- @integrations} id={"integration-#{integration.id}"}>
              <td>
                <.link navigate={path(:show, integration.id)} class="link link-hover font-medium">
                  {integration.name}
                </.link>
              </td>
              <td><.resource_badge value={integration.resource} /></td>
              <td class="text-sm text-base-content/80">
                {Enum.map_join(integration.actions, ", ", &humanize/1)}
              </td>
              <td>V{integration.schema_version}</td>
              <td>{humanize(integration.transport)}</td>
              <td class="text-sm">{Helpers.owner_name(integration)}</td>
              <td><.active_badge active={integration.active} /></td>
              <td>
                <span class={[
                  "badge badge-sm",
                  if(integration.consecutive_failures > 0, do: "badge-warning", else: "badge-ghost")
                ]}>
                  {integration.consecutive_failures}
                </span>
              </td>
              <td class="text-sm text-base-content/60">
                {Helpers.format_datetime(integration.created_at)}
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
                    <li><.link navigate={path(:show, integration.id)}>View</.link></li>
                    <li><.link patch={path(:edit, integration.id)}>Edit</.link></li>
                    <li><.link navigate={path(:test, integration.id)}>Test</.link></li>
                    <li>
                      <button
                        phx-click="delete"
                        phx-value-id={integration.id}
                        data-confirm="Are you sure?"
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
        id="integration-modal"
        show
        on_cancel={JS.navigate(path(:index))}
      >
        <h3 class="text-lg font-bold mb-4">
          {if @live_action == :new, do: "New Outbound Integration", else: "Edit Outbound Integration"}
        </h3>
        <.live_component
          module={FormComponent}
          id="integration-form"
          action={@live_action}
          integration={assigns[:integration]}
          actor={@current_user}
          navigate={path(:index)}
        />
      </.modal>
    </div>
    """
  end

  defp path(:index), do: integration_base_path()
  defp path(:new), do: "#{integration_base_path()}/new"
  defp path(:logs), do: "#{integration_base_path()}/logs/all"
  defp path(:show, id), do: "#{integration_base_path()}/#{id}"
  defp path(:edit, id), do: "#{integration_base_path()}/edit/#{id}"
  defp path(:test, id), do: "#{integration_base_path()}/#{id}/test"

  defp integration_base_path do
    AshIntegration.Web.base_path()
  end
end
