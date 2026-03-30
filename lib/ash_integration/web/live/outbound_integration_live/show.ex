defmodule AshIntegration.Web.OutboundIntegrationLive.Show do
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.OutboundIntegrationLive.{Helpers, FormComponent}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    case Ash.get(resource, id, actor: actor, load: [:owner, :delivery_logs]) do
      {:ok, integration} ->
        {:ok,
         socket
         |> assign(integration: integration)
         |> assign(page_title: integration.name)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Integration not found")
         |> push_navigate(to: base_path())}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    assign(socket, test_result: nil, testing: false)
  end

  defp apply_action(socket, :edit, _params) do
    assign(socket,
      page_title: "Edit #{socket.assigns.integration.name}",
      test_result: nil,
      testing: false
    )
  end

  defp apply_action(socket, :test, _params) do
    assign(socket, test_result: nil, testing: false)
  end

  @impl true
  def handle_event("activate", _, socket) do
    handle_action(socket, :activate, "Integration activated")
  end

  def handle_event("deactivate", _, socket) do
    handle_action(socket, :deactivate, "Integration deactivated")
  end

  def handle_event("delete", _, socket) do
    actor = socket.assigns.current_user

    case Ash.destroy(socket.assigns.integration, actor: actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Integration deleted")
         |> push_navigate(to: base_path())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete integration")}
    end
  end

  def handle_event("run_test", %{"action" => action}, socket) do
    actor = socket.assigns.current_user
    integration = socket.assigns.integration
    resource = AshIntegration.outbound_integration_resource()

    socket = assign(socket, testing: true)

    case resource
         |> Ash.ActionInput.for_action(:test, %{
           outbound_integration_id: integration.id,
           action: action
         })
         |> Ash.run_action(actor: actor) do
      {:ok, result} ->
        {:noreply, assign(socket, test_result: result, testing: false)}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(testing: false, test_result: %{error: inspect(error)})}
    end
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, load_delivery_logs(socket, Helpers.parse_int(offset, 0))}
  end

  @impl true
  def handle_info({FormComponent, {:saved, updated}}, socket) do
    integration = Ash.load!(updated, [:owner], actor: socket.assigns.current_user)
    {:noreply, assign(socket, integration: integration)}
  end

  defp handle_action(socket, action_name, success_msg) do
    actor = socket.assigns.current_user
    integration = socket.assigns.integration

    case Ash.update(integration, %{}, action: action_name, actor: actor) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(integration: Ash.load!(updated, [:owner], actor: actor))
         |> put_flash(:info, success_msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Action failed")}
    end
  end

  defp load_delivery_logs(socket, offset) do
    delivery_log_resource = AshIntegration.delivery_log_resource()
    actor = socket.assigns.current_user
    integration = socket.assigns.integration

    case delivery_log_resource
         |> Ash.Query.for_read(
           :for_outbound_integration,
           %{outbound_integration_id: integration.id},
           actor: actor
         )
         |> Ash.read(actor: actor, page: [limit: 10, offset: offset, count: true]) do
      {:ok, page} ->
        assign(socket,
          recent_logs: page.results,
          logs_page: %{offset: page.offset || 0, limit: page.limit || 10, count: page.count}
        )

      {:error, _} ->
        assign(socket, recent_logs: [], logs_page: %{offset: 0, limit: 10, count: 0})
    end
  end

  defp base_path, do: AshIntegration.Web.base_path()

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.back_link navigate={base_path()} label="Back to Integrations" />

      <.page_header>
        {@integration.name}
        <:subtitle>
          <.resource_badge value={@integration.resource} />
          <.active_badge active={@integration.active} />
        </:subtitle>
        <:actions>
          <div class="flex gap-2">
            <button
              :if={!@integration.active}
              class="btn btn-success btn-sm"
              phx-click="activate"
            >
              Activate
            </button>
            <button
              :if={@integration.active}
              class="btn btn-warning btn-sm"
              phx-click="deactivate"
            >
              Deactivate
            </button>
            <.link patch={"#{base_path()}/#{@integration.id}/edit"} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil-square-mini" /> Edit
            </.link>
            <.link patch={"#{base_path()}/#{@integration.id}/test"} class="btn btn-ghost btn-sm">
              <.icon name="hero-play-mini" /> Test
            </.link>
            <button
              class="btn btn-error btn-sm"
              phx-click="delete"
              data-confirm="Are you sure you want to delete this integration?"
            >
              <.icon name="hero-trash-mini" /> Delete
            </button>
          </div>
        </:actions>
      </.page_header>

      <%= case @live_action do %>
        <% :show -> %>
          <.show_detail integration={@integration} />
        <% :edit -> %>
          <.show_detail integration={@integration} />
        <% :test -> %>
          <.test_panel
            integration={@integration}
            test_result={@test_result}
            testing={@testing}
          />
      <% end %>

      <.modal
        :if={@live_action == :edit}
        id="edit-integration-modal"
        show
        on_cancel={JS.navigate("#{base_path()}/#{@integration.id}")}
      >
        <h3 class="text-lg font-bold mb-4">Edit Outbound Integration</h3>
        <.live_component
          module={FormComponent}
          id="edit-integration-form"
          action={:edit}
          integration={@integration}
          actor={@current_user}
          navigate={"#{base_path()}/#{@integration.id}"}
        />
      </.modal>
    </div>
    """
  end

  attr :integration, :any, required: true

  defp show_detail(assigns) do
    ~H"""
    <div class="grid gap-4 md:grid-cols-2 mt-4">
      <div class="card card-border border-base-300 bg-base-200/30 p-5">
        <h3 class="font-semibold mb-3">General</h3>
        <dl class="space-y-2 text-sm">
          <div class="flex justify-between">
            <dt class="text-base-content/60">Name</dt>
            <dd>{@integration.name}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Resource</dt>
            <dd><.resource_badge value={@integration.resource} /></dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Actions</dt>
            <dd>{Enum.map_join(@integration.actions, ", ", &humanize/1)}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Schema Version</dt>
            <dd>V{@integration.schema_version}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Owner</dt>
            <dd>{Helpers.owner_name(@integration)}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Status</dt>
            <dd><.active_badge active={@integration.active} /></dd>
          </div>
          <div :if={@integration.deactivation_reason} class="flex justify-between">
            <dt class="text-base-content/60">Deactivation Reason</dt>
            <dd>{humanize(@integration.deactivation_reason)}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Consecutive Failures</dt>
            <dd>{@integration.consecutive_failures}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Created</dt>
            <dd>{Helpers.format_datetime(@integration.created_at, :long)}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">Updated</dt>
            <dd>{Helpers.format_datetime(@integration.updated_at, :long)}</dd>
          </div>
        </dl>
      </div>

      <div class="card card-border border-base-300 bg-base-200/30 p-5">
        <h3 class="font-semibold mb-3">Transport Configuration</h3>
        <.transport_config_detail config={@integration.transport_config} />

        <div class="divider"></div>
        <h3 class="font-semibold mb-3">Transform Script</h3>
        <pre class="bg-base-300 p-3 rounded-lg text-xs overflow-x-auto max-h-60"><code>{@integration.transform_script}</code></pre>
      </div>
    </div>
    """
  end

  attr :config, :any, required: true

  defp transport_config_detail(%{config: %Ash.Union{type: :http, value: value}} = assigns) do
    assigns = Phoenix.Component.assign(assigns, :config, value)

    ~H"""
    <dl class="space-y-2 text-sm">
      <div class="flex justify-between">
        <dt class="text-base-content/60">Method</dt>
        <dd>{(@config.method || :post) |> to_string() |> String.upcase()}</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">URL</dt>
        <dd class="truncate max-w-xs">{@config.url}</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Timeout</dt>
        <dd>{@config.timeout_ms}ms</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Auth Method</dt>
        <dd>{humanize(@config.auth.type)}</dd>
      </div>
      <div :if={@config.headers != nil and @config.headers != %{}} class="flex justify-between">
        <dt class="text-base-content/60">Custom Headers</dt>
        <dd class="truncate max-w-xs">{map_size(@config.headers)} header(s)</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">HMAC Signing</dt>
        <dd>
          {if @config.encrypted_signing_secret, do: "Enabled", else: "Disabled"}
        </dd>
      </div>
    </dl>
    """
  end

  defp transport_config_detail(assigns) do
    ~H"""
    <span class="text-base-content/50">—</span>
    """
  end

  attr :integration, :any, required: true
  attr :test_result, :any, required: true
  attr :testing, :boolean, required: true

  defp test_panel(assigns) do
    ~H"""
    <div class="mt-4 max-w-3xl">
      <div class="card card-border border-base-300 bg-base-200/30 p-5">
        <h3 class="font-semibold mb-3">Test Transform</h3>
        <p class="text-sm text-base-content/60 mb-4">
          Select an action to test the transform script with a sample resource from the database.
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={action <- @integration.actions}
            class="btn btn-sm btn-outline"
            phx-click="run_test"
            phx-value-action={action}
            disabled={@testing}
          >
            <.icon :if={@testing} name="hero-arrow-path" class="animate-spin size-4" />
            Test "{humanize(action)}"
          </button>
        </div>
      </div>

      <div :if={@test_result} class="mt-4 space-y-4">
        <div :if={@test_result[:error]} class="alert alert-error">
          <.icon name="hero-exclamation-triangle-mini" />
          <span>{@test_result[:error] || @test_result.error}</span>
        </div>

        <div :if={@test_result[:skipped]} class="alert alert-warning">
          <.icon name="hero-forward-mini" />
          <span>
            Transform script returned <code>skip</code> — this event would not be delivered.
          </span>
        </div>

        <div :if={@test_result[:input]} class="card card-border border-base-300 bg-base-200/30 p-5">
          <h4 class="font-semibold mb-2">Input (Event Data)</h4>
          <pre class="bg-base-300 p-3 rounded-lg text-xs overflow-x-auto max-h-80"><code>{format_json(@test_result[:input] || @test_result.input)}</code></pre>
        </div>

        <div :if={@test_result[:output]} class="card card-border border-base-300 bg-base-200/30 p-5">
          <h4 class="font-semibold mb-2">Output (Transformed Payload)</h4>
          <pre class="bg-base-300 p-3 rounded-lg text-xs overflow-x-auto max-h-80"><code>{format_json(@test_result[:output] || @test_result.output)}</code></pre>
        </div>
      </div>
    </div>
    """
  end

  defp format_json(nil), do: "null"
  defp format_json(data) when is_map(data) or is_list(data), do: Jason.encode!(data, pretty: true)
  defp format_json(data), do: inspect(data, pretty: true)
end
