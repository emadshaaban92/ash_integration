defmodule AshIntegration.Web.OutboundIntegrationLive.Show do
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Web.OutboundIntegrationLive.{Helpers, FormComponent}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    case Ash.get(resource, id, actor: actor, load: [:owner]) do
      {:ok, integration} ->
        {:ok,
         socket
         |> assign(integration: integration)
         |> assign(page_title: integration.name)
         |> assign_event_counts(integration)
         |> load_outbound_integration_logs(0)}

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
           integration_id: integration.id,
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
    {:noreply, load_outbound_integration_logs(socket, Helpers.parse_int(offset, 0))}
  end

  def handle_event("suspend", _params, socket) do
    actor = socket.assigns.current_user
    integration = socket.assigns.integration

    case integration
         |> Ash.Changeset.for_update(:suspend, %{reason: "Manual suspension"})
         |> Ash.update(actor: actor) do
      {:ok, updated} ->
        updated = Ash.load!(updated, [:owner], actor: actor)

        {:noreply,
         socket
         |> assign(integration: updated)
         |> assign_event_counts(updated)
         |> put_flash(:info, "Integration suspended")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to suspend integration")}
    end
  end

  def handle_event("unsuspend", _params, socket) do
    actor = socket.assigns.current_user
    integration = socket.assigns.integration

    case integration
         |> Ash.Changeset.for_update(:unsuspend, %{})
         |> Ash.update(actor: actor) do
      {:ok, updated} ->
        updated = Ash.load!(updated, [:owner], actor: actor)
        AshIntegration.EventScheduler.notify()

        {:noreply,
         socket
         |> assign(integration: updated)
         |> assign_event_counts(updated)
         |> put_flash(:info, "Integration unsuspended — backlog will begin draining")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unsuspend integration")}
    end
  end

  def handle_event("bulk_reprocess", _params, socket) do
    actor = socket.assigns.current_user
    integration = socket.assigns.integration
    resource = AshIntegration.outbound_integration_resource()

    case resource
         |> Ash.ActionInput.for_action(:bulk_reprocess, %{integration: integration})
         |> Ash.run_action(actor: actor) do
      {:ok, %{reprocessed: reprocessed, failed: failed}} ->
        updated = Ash.load!(integration, [:owner], actor: actor)

        {:noreply,
         socket
         |> assign(integration: updated)
         |> assign_event_counts(updated)
         |> put_flash(:info, "Reprocessed #{reprocessed} event(s), #{failed} still failed")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to run bulk reprocess")}
    end
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

  defp load_outbound_integration_logs(socket, offset) do
    log_resource = AshIntegration.outbound_integration_log_resource()
    actor = socket.assigns.current_user
    integration = socket.assigns.integration

    case log_resource
         |> Ash.Query.for_read(
           :for_integration,
           %{integration_id: integration.id},
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

  defp assign_event_counts(socket, integration) do
    actor = socket.assigns.current_user
    event_resource = AshIntegration.outbound_integration_event_resource()

    pending_count =
      event_resource
      |> Ash.Query.filter(integration_id == ^integration.id and state == :pending)
      |> Ash.count!(actor: actor)

    scheduled_count =
      event_resource
      |> Ash.Query.filter(integration_id == ^integration.id and state == :scheduled)
      |> Ash.count!(actor: actor)

    stuck_count =
      event_resource
      |> Ash.Query.filter(
        integration_id == ^integration.id and state == :pending and is_nil(payload)
      )
      |> Ash.count!(actor: actor)

    assign(socket,
      pending_event_count: pending_count,
      scheduled_event_count: scheduled_count,
      stuck_event_count: stuck_count
    )
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
          <span :if={@integration.suspended} class="badge badge-error">Suspended</span>
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
            <button
              :if={@integration.suspended}
              class="btn btn-info btn-sm"
              phx-click="unsuspend"
            >
              Unsuspend
            </button>
            <button
              :if={!@integration.suspended && @integration.active}
              class="btn btn-outline btn-sm"
              phx-click="suspend"
              data-confirm="Suspend this integration? Delivery will stop but events will keep accumulating."
            >
              Suspend
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

      <div :if={@integration.suspended} class="alert alert-error mb-4">
        <.icon name="hero-pause-circle-mini" />
        <div>
          <p class="font-bold">Integration Suspended</p>
          <p :if={@integration.suspension_reason} class="text-sm">
            {@integration.suspension_reason}
          </p>
          <p :if={@integration.suspended_at} class="text-sm text-base-content/60">
            Since {Helpers.format_datetime(@integration.suspended_at, :long)}
          </p>
        </div>
      </div>

      <div class="stats shadow mb-4">
        <div class="stat">
          <div class="stat-title">Pending</div>
          <div class="stat-value text-warning">{@pending_event_count}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Scheduled</div>
          <div class="stat-value text-info">{@scheduled_event_count}</div>
        </div>
        <div :if={@stuck_event_count > 0} class="stat">
          <div class="stat-title">Stuck (no payload)</div>
          <div class="stat-value text-error">{@stuck_event_count}</div>
        </div>
        <div class="stat">
          <div class="stat-desc mt-2">
            <.link
              navigate={"#{base_path()}/#{@integration.id}/events"}
              class="btn btn-sm btn-outline"
            >
              View Events
            </.link>
            <button
              :if={@stuck_event_count > 0}
              class="btn btn-sm btn-warning ml-2"
              phx-click="bulk_reprocess"
              data-confirm={"Reprocess #{@stuck_event_count} stuck event(s)?"}
            >
              Reprocess All Failed
            </button>
          </div>
        </div>
      </div>

      <%= case @live_action do %>
        <% :show -> %>
          <.show_detail integration={@integration} />
          <.recent_logs
            integration={@integration}
            logs={@recent_logs}
            logs_page={@logs_page}
          />
        <% :edit -> %>
          <.show_detail integration={@integration} />
          <.recent_logs
            integration={@integration}
            logs={@recent_logs}
            logs_page={@logs_page}
          />
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

  attr :integration, :any, required: true
  attr :logs, :list, required: true
  attr :logs_page, :map, required: true

  defp recent_logs(assigns) do
    ~H"""
    <div class="mt-6">
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold">Recent Delivery Logs</h3>
        <.link
          navigate={"#{base_path()}/logs/all?integration_id=#{@integration.id}"}
          class="btn btn-ghost btn-xs"
        >
          View all logs <.icon name="hero-arrow-right-mini" class="size-4" />
        </.link>
      </div>

      <div :if={@logs == []} class="text-sm text-base-content/50 py-4">
        No delivery logs yet for this integration.
      </div>

      <div :if={@logs != []} class="overflow-x-auto">
        <table class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>Resource</th>
              <th>Action</th>
              <th>Status</th>
              <th>HTTP Status</th>
              <th>Duration</th>
              <th>Error</th>
              <th>Created</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={log <- @logs} id={"log-#{log.id}"}>
              <td><.resource_badge value={log.resource} /></td>
              <td class="text-sm">{humanize(log.action)}</td>
              <td><.status_badge status={log.status} /></td>
              <td>
                <span
                  :if={log.response_status}
                  class={[
                    "badge badge-sm",
                    cond do
                      log.response_status < 300 -> "badge-success"
                      log.response_status < 400 -> "badge-warning"
                      true -> "badge-error"
                    end
                  ]}
                >
                  {log.response_status}
                </span>
                <span :if={is_nil(log.response_status)} class="text-base-content/50">—</span>
              </td>
              <td class="text-sm">
                <span :if={log.duration_ms}>{log.duration_ms}ms</span>
                <span :if={is_nil(log.duration_ms)} class="text-base-content/50">—</span>
              </td>
              <td class="text-sm text-error max-w-xs truncate">{log.error_message}</td>
              <td class="text-sm text-base-content/60">
                {Helpers.format_datetime(log.created_at, :long)}
              </td>
              <td>
                <.link navigate={"#{base_path()}/logs/#{log.id}"} class="btn btn-ghost btn-xs">
                  View
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
        <.pagination page={@logs_page} />
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

  defp transport_config_detail(%{config: %Ash.Union{type: :kafka, value: value}} = assigns) do
    assigns = Phoenix.Component.assign(assigns, :config, value)

    ~H"""
    <dl class="space-y-2 text-sm">
      <div class="flex justify-between">
        <dt class="text-base-content/60">Transport</dt>
        <dd>Kafka</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Topic</dt>
        <dd>{@config.topic}</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Brokers</dt>
        <dd class="truncate max-w-xs">{Enum.join(@config.brokers, ", ")}</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Acknowledgements</dt>
        <dd>{humanize(@config.acks)}</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Security</dt>
        <dd>{security_label(@config.security)}</dd>
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

  defp transport_config_detail(%{config: %Ash.Union{type: :grpc, value: value}} = assigns) do
    assigns = Phoenix.Component.assign(assigns, :config, value)

    ~H"""
    <dl class="space-y-2 text-sm">
      <div class="flex justify-between">
        <dt class="text-base-content/60">Transport</dt>
        <dd>gRPC</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Endpoint</dt>
        <dd class="truncate max-w-xs">{@config.endpoint}</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Service / Method</dt>
        <dd class="truncate max-w-xs">{@config.service}/{@config.method}</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Timeout</dt>
        <dd>{@config.timeout_ms}ms</dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-base-content/60">Security</dt>
        <dd>{grpc_security_label(@config.security)}</dd>
      </div>
      <div :if={@config.headers != nil and @config.headers != %{}} class="flex justify-between">
        <dt class="text-base-content/60">Custom Metadata</dt>
        <dd class="truncate max-w-xs">{map_size(@config.headers)} key(s)</dd>
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

  defp security_label(%Ash.Union{type: :none}), do: "None"
  defp security_label(%Ash.Union{type: :tls}), do: "TLS"

  defp security_label(%Ash.Union{type: :sasl, value: v}),
    do: "SASL (#{humanize(v.mechanism)})"

  defp security_label(%Ash.Union{type: :sasl_tls, value: v}),
    do: "SASL + TLS (#{humanize(v.mechanism)})"

  defp security_label(_), do: "—"

  defp grpc_security_label(%Ash.Union{type: :none}), do: "None (H2C)"
  defp grpc_security_label(%Ash.Union{type: :tls}), do: "TLS"
  defp grpc_security_label(%Ash.Union{type: :bearer_token}), do: "Bearer Token"
  defp grpc_security_label(%Ash.Union{type: :mutual_tls}), do: "Mutual TLS"
  defp grpc_security_label(_), do: "—"

  defp format_json(nil), do: "null"
  defp format_json(data) when is_map(data) or is_list(data), do: Jason.encode!(data, pretty: true)
  defp format_json(data), do: inspect(data, pretty: true)
end
