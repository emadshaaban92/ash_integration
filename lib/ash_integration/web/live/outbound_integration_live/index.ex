defmodule AshIntegration.Web.OutboundIntegrationLive.Index do
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Outbound Integrations",
       integrations: [],
       page: %{offset: 0, limit: 20, count: 0},
       form: nil,
       resource_options: [],
       action_options: [],
       schema_version_options: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    form =
      AshPhoenix.Form.for_create(resource, :create, actor: actor, forms: [auto?: true])
      |> AshPhoenix.Form.add_form("form[transport_config]")
      |> Helpers.ensure_auth_subform()

    socket
    |> assign(page_title: "New Outbound Integration")
    |> assign(form: form)
    |> assign(header_rows: [])
    |> Helpers.assign_form_options(form)
    |> load_integrations(0)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    case Ash.get(resource, id, actor: actor) do
      {:ok, integration} ->
        form =
          AshPhoenix.Form.for_update(integration, :update, actor: actor, forms: [auto?: true])
          |> Helpers.ensure_auth_subform()

        header_rows =
          ((integration.transport_config && integration.transport_config.headers) || %{})
          |> Enum.map(fn {k, v} -> {System.unique_integer([:positive]), {k, v}} end)

        socket
        |> assign(page_title: "Edit #{integration.name}")
        |> assign(form: form)
        |> assign(header_rows: header_rows)
        |> Helpers.assign_form_options(form)
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
    |> assign_new(:header_rows, fn -> [] end)
    |> assign(page_title: "Outbound Integrations", form: nil)
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

  def handle_event("add-header", _, socket) do
    id = System.unique_integer([:positive])
    {:noreply, assign(socket, header_rows: socket.assigns.header_rows ++ [{id, {"", ""}}])}
  end

  def handle_event("remove-header", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.header_rows, fn {row_id, _} -> row_id == id end)
    {:noreply, assign(socket, header_rows: rows)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    params = inject_headers_map(params)
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    {:noreply,
     socket
     |> assign(form: form)
     |> Helpers.assign_form_options(form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    params = inject_headers_map(params)

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _record} ->
        message =
          if socket.assigns.live_action == :edit,
            do: "Integration updated",
            else: "Integration created"

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: path(:index))}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("auth-type-changed", %{"_target" => path} = params, socket) do
    new_type = get_in(params, path)
    form_path = :lists.droplast(path)

    form =
      socket.assigns.form
      |> AshPhoenix.Form.remove_form(form_path)
      |> AshPhoenix.Form.add_form(form_path, params: %{"_union_type" => new_type})

    {:noreply,
     socket
     |> assign(form: form)
     |> Helpers.assign_form_options(form)}
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
        <.form
          :let={f}
          for={@form}
          id="integration-form"
          phx-change="validate"
          phx-submit="save"
        >
          <.integration_form_fields
            form={f}
            resource_options={@resource_options}
            action_options={@action_options}
            schema_version_options={@schema_version_options}
            actor={@current_user}
            header_rows={@header_rows}
          />
          <div class="modal-action">
            <button type="button" class="btn" phx-click={JS.navigate(path(:index))}>Cancel</button>
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
              {if @live_action == :new, do: "Create", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :resource_options, :list, required: true
  attr :action_options, :list, required: true
  attr :schema_version_options, :list, required: true
  attr :actor, :any, default: nil
  attr :header_rows, :list, default: []

  def integration_form_fields(assigns) do
    ~H"""
    <div class="space-y-4">
      <.input field={@form[:name]} type="text" label="Name" required phx-debounce="blur" />
      <.input
        field={@form[:resource]}
        type="select"
        label="Resource"
        options={@resource_options}
        required
      />
      <.input
        field={@form[:actions]}
        type="select"
        label="Actions"
        options={@action_options}
        multiple
        required
        size="4"
      />
      <.input
        field={@form[:schema_version]}
        type="select"
        label="Schema Version"
        options={@schema_version_options}
        required
      />
      <.live_component
        id="select-owner_id"
        module={AshIntegration.Web.Components.BelongsToInput}
        label="Owner"
        relationship={
          Ash.Resource.Info.relationship(AshIntegration.outbound_integration_resource(), :owner)
        }
        form={@form}
        actor={@actor}
      />
      <.input
        field={@form[:transform_script]}
        type="textarea"
        label="Transform Script"
        required
        phx-debounce="blur"
        rows="6"
      />

      <.inputs_for :let={tc} field={@form[:transport_config]}>
        <div class="card card-border border-base-300 p-4 mt-4">
          <h4 class="font-semibold mb-3">HTTP Configuration</h4>
          <.input
            field={tc[:method]}
            type="select"
            label="HTTP Method"
            options={[{"POST", "post"}, {"PUT", "put"}, {"PATCH", "patch"}, {"DELETE", "delete"}]}
          />
          <.input
            field={tc[:url]}
            type="text"
            label="URL"
            placeholder="https://example.com/webhook"
            required
            phx-debounce="blur"
          />
          <.input
            field={tc[:timeout_ms]}
            type="text"
            label="Timeout (ms)"
            required
            phx-debounce="blur"
          />
          <label class="label">Custom Headers</label>
          <div class="space-y-2">
            <div :for={{id, {key, value}} <- @header_rows} class="flex gap-2 items-center">
              <input
                type="text"
                name={tc[:headers].name <> "[#{id}][key]"}
                value={key}
                placeholder="Header name"
                class="input input-bordered input-sm flex-1"
                phx-debounce="blur"
              />
              <input
                type="text"
                name={tc[:headers].name <> "[#{id}][value]"}
                value={value}
                placeholder="Header value"
                class="input input-bordered input-sm flex-1"
                phx-debounce="blur"
              />
              <button
                type="button"
                phx-click="remove-header"
                phx-value-id={id}
                class="btn btn-ghost btn-sm btn-square"
              >
                &times;
              </button>
            </div>
            <button type="button" phx-click="add-header" class="btn btn-outline btn-xs">
              + Add Header
            </button>
          </div>

          <div class="divider my-2"></div>
          <h5 class="font-semibold mb-3">Webhook Signing</h5>
          <.input
            field={tc[:signing_secret]}
            type="password"
            autocomplete="one-time-code"
            label="HMAC Signing Secret"
            placeholder="Leave blank to disable signing"
            phx-debounce="blur"
          />
          <p class="text-xs text-base-content/50 mt-1">
            When set, payloads are signed with HMAC-SHA256. The signature is sent in the
            <code class="text-xs">x-webhook-signature</code>
            header as <code class="text-xs">t=timestamp,v1=hex_digest</code>.
          </p>

          <div class="divider my-2"></div>
          <h5 class="font-semibold mb-3">Authentication</h5>

          <.inputs_for :let={auth} field={tc[:auth]}>
            <.input
              field={auth[:_union_type]}
              phx-change="auth-type-changed"
              type="select"
              label="Auth Method"
              options={[
                {"No Auth", "none"},
                {"Bearer Token", "bearer_token"},
                {"API Key", "api_key"},
                {"Basic Auth", "basic_auth"}
              ]}
            />
            <%= case auth.params["_union_type"] do %>
              <% "bearer_token" -> %>
                <.input
                  field={auth[:token]}
                  type="password"
                  autocomplete="one-time-code"
                  label="Token"
                  required
                  phx-debounce="blur"
                />
              <% "api_key" -> %>
                <.input
                  field={auth[:header_name]}
                  type="text"
                  label="Header Name"
                  required
                  phx-debounce="blur"
                />
                <.input
                  field={auth[:value]}
                  type="password"
                  autocomplete="one-time-code"
                  label="API Key Value"
                  required
                  phx-debounce="blur"
                />
              <% "basic_auth" -> %>
                <.input
                  field={auth[:username]}
                  type="text"
                  label="Username"
                  required
                  phx-debounce="blur"
                />
                <.input
                  field={auth[:password]}
                  type="password"
                  autocomplete="one-time-code"
                  label="Password"
                  required
                  phx-debounce="blur"
                />
              <% _ -> %>
            <% end %>
          </.inputs_for>
        </div>
      </.inputs_for>
    </div>
    """
  end

  defp inject_headers_map(params) do
    case get_in(params, ["transport_config", "headers"]) do
      raw when is_map(raw) ->
        headers_map =
          raw
          |> Map.values()
          |> Enum.reject(fn entry -> entry["key"] == "" end)
          |> Map.new(fn entry -> {entry["key"], entry["value"] || ""} end)

        put_in(params, ["transport_config", "headers"], headers_map)

      _ ->
        params
    end
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
