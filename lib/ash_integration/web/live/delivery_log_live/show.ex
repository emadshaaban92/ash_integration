defmodule AshIntegration.Web.DeliveryLogLive.Show do
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = AshIntegration.delivery_log_resource()
    actor = socket.assigns.current_user

    case Ash.get(resource, id, actor: actor, load: [:outbound_integration]) do
      {:ok, log} ->
        {:ok,
         socket
         |> assign(log: log)
         |> assign(page_title: "Delivery Log")}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Delivery log not found")
         |> push_navigate(to: "#{base_path()}/logs/all")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp base_path, do: AshIntegration.Web.base_path()

  defp integration_name(%{outbound_integration: %{name: name}}) when is_binary(name), do: name
  defp integration_name(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.back_link navigate={"#{base_path()}/logs/all"} label="Back to Delivery Logs" />

      <.page_header>
        Delivery Log
        <:subtitle>
          <.status_badge status={@log.status} />
          <.resource_badge value={@log.resource} />
        </:subtitle>
      </.page_header>

      <div class="grid gap-4 md:grid-cols-2 mt-4">
        <div class="card card-border border-base-300 bg-base-200/30 p-5">
          <h3 class="font-semibold mb-3">Details</h3>
          <dl class="space-y-2 text-sm">
            <div class="flex justify-between">
              <dt class="text-base-content/60">Integration</dt>
              <dd>{integration_name(@log)}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Resource</dt>
              <dd><.resource_badge value={@log.resource} /></dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Action</dt>
              <dd>{humanize(@log.action)}</dd>
            </div>
            <div :if={@log.schema_version} class="flex justify-between">
              <dt class="text-base-content/60">Schema Version</dt>
              <dd>V{@log.schema_version}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Event ID</dt>
              <dd class="font-mono text-xs">{@log.event_id}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Resource ID</dt>
              <dd class="font-mono text-xs">{@log.resource_id}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Status</dt>
              <dd><.status_badge status={@log.status} /></dd>
            </div>
            <div :if={@log.response_status} class="flex justify-between">
              <dt class="text-base-content/60">HTTP Status</dt>
              <dd>
                <span class={[
                  "badge badge-sm",
                  cond do
                    @log.response_status < 300 -> "badge-success"
                    @log.response_status < 400 -> "badge-warning"
                    true -> "badge-error"
                  end
                ]}>
                  {@log.response_status}
                </span>
              </dd>
            </div>
            <div :if={@log.duration_ms} class="flex justify-between">
              <dt class="text-base-content/60">Duration</dt>
              <dd>{@log.duration_ms}ms</dd>
            </div>
            <div :if={@log.error_message} class="flex justify-between">
              <dt class="text-base-content/60">Error</dt>
              <dd class="text-error max-w-sm break-words">{@log.error_message}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Created</dt>
              <dd>{Helpers.format_datetime(@log.created_at, :long)}</dd>
            </div>
          </dl>
        </div>

        <div class="space-y-4">
          <div :if={@log.request_payload} class="card card-border border-base-300 bg-base-200/30 p-5">
            <h3 class="font-semibold mb-3">Request Payload</h3>
            <pre class="bg-base-300 p-3 rounded-lg text-xs overflow-x-auto max-h-60"><code>{format_json(@log.request_payload)}</code></pre>
          </div>

          <div :if={@log.response_body} class="card card-border border-base-300 bg-base-200/30 p-5">
            <h3 class="font-semibold mb-3">Response Body</h3>
            <pre class="bg-base-300 p-3 rounded-lg text-xs overflow-x-auto max-h-60"><code>{@log.response_body}</code></pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_json(nil), do: "null"
  defp format_json(data) when is_map(data) or is_list(data), do: Jason.encode!(data, pretty: true)
  defp format_json(data), do: inspect(data, pretty: true)
end
