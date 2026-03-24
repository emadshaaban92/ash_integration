defmodule AshIntegration.Web.DeliveryLogLive.Index do
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Delivery Logs")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    offset = parse_int(params["offset"], 0)
    {:noreply, load_logs(socket, offset)}
  end

  defp load_logs(socket, offset) do
    resource = AshIntegration.delivery_log_resource()
    actor = socket.assigns.current_user

    case resource
         |> Ash.Query.for_read(:index, %{}, actor: actor)
         |> Ash.Query.load(:outbound_integration)
         |> Ash.read(actor: actor, page: [limit: 20, offset: offset, count: true]) do
      {:ok, page} ->
        assign(socket,
          logs: page.results,
          page: %{offset: page.offset || 0, limit: page.limit || 20, count: page.count}
        )

      {:error, _} ->
        assign(socket, logs: [], page: %{offset: 0, limit: 20, count: 0})
    end
  end

  @impl true
  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, load_logs(socket, parse_int(offset, 0))}
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val

  defp base_path, do: AshIntegration.Web.base_path()

  defp integration_name(%{outbound_integration: %{name: name}}) when is_binary(name), do: name
  defp integration_name(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.back_link navigate={base_path()} label="Back to Integrations" />

      <.page_header>
        Delivery Logs
      </.page_header>

      <div :if={@logs == []}>
        <.empty_state title="No delivery logs yet" icon="hero-document-text" />
      </div>

      <div :if={@logs != []} class="overflow-x-auto">
        <table class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>Integration</th>
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
              <td class="font-medium">{integration_name(log)}</td>
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
        <.pagination page={@page} />
      </div>
    </div>
    """
  end
end
