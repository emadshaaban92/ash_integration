defmodule AshIntegration.Web.OutboundIntegrationLogLive.Index do
  use AshIntegration.Web, :live_view

  require Ash.Query

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @statuses ~w(all success failed skipped)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Integration Logs",
       integrations: load_integrations(socket),
       filter_integration_id: nil,
       filter_status: :all
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    offset = parse_int(params["offset"], 0)
    integration_id = params["integration_id"]
    status = parse_status(params["status"])

    {:noreply,
     socket
     |> assign(filter_integration_id: integration_id, filter_status: status)
     |> load_logs(offset)}
  end

  defp load_integrations(socket) do
    resource = AshIntegration.outbound_integration_resource()
    actor = socket.assigns.current_user

    case Ash.read(resource, actor: actor) do
      {:ok, integrations} -> integrations
      {:error, _} -> []
    end
  end

  defp load_logs(socket, offset) do
    resource = AshIntegration.outbound_integration_log_resource()
    actor = socket.assigns.current_user
    integration_id = socket.assigns.filter_integration_id
    status = socket.assigns.filter_status

    query =
      resource
      |> Ash.Query.for_read(:index, %{}, actor: actor)
      |> Ash.Query.load(:integration)

    query =
      if integration_id && integration_id != "" do
        Ash.Query.filter(query, integration_id == ^integration_id)
      else
        query
      end

    query =
      if status && status != :all do
        Ash.Query.filter(query, status == ^status)
      else
        query
      end

    case Ash.read(query, actor: actor, page: [limit: 20, offset: offset, count: true]) do
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
  def handle_event("filter", params, socket) do
    integration_id = params["integration_id"]
    status = params["status"] || to_string(socket.assigns.filter_status)

    query_params =
      %{}
      |> then(fn p ->
        if integration_id && integration_id != "",
          do: Map.put(p, "integration_id", integration_id),
          else: p
      end)
      |> then(fn p -> if status && status != "all", do: Map.put(p, "status", status), else: p end)

    path =
      case URI.encode_query(query_params) do
        "" -> "#{base_path()}/logs/all"
        qs -> "#{base_path()}/logs/all?#{qs}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    integration_id = socket.assigns.filter_integration_id

    query_params =
      %{}
      |> then(fn p ->
        if integration_id && integration_id != "",
          do: Map.put(p, "integration_id", integration_id),
          else: p
      end)
      |> then(fn p -> if status && status != "all", do: Map.put(p, "status", status), else: p end)

    path =
      case URI.encode_query(query_params) do
        "" -> "#{base_path()}/logs/all"
        qs -> "#{base_path()}/logs/all?#{qs}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("paginate", %{"offset" => offset}, socket) do
    {:noreply, load_logs(socket, parse_int(offset, 0))}
  end

  defp parse_status(nil), do: :all
  defp parse_status(""), do: :all

  defp parse_status(val) when is_binary(val) do
    atom = String.to_existing_atom(val)
    if atom in @statuses, do: atom, else: :all
  rescue
    ArgumentError -> :all
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

  defp integration_name(%{integration: %{name: name}}) when is_binary(name), do: name
  defp integration_name(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.back_link navigate={base_path()} label="Back to Integrations" />

      <.page_header>
        Integration Logs
      </.page_header>

      <div class="flex flex-wrap items-center gap-3 mb-4">
        <form phx-change="filter" class="flex items-center gap-3">
          <select
            name="integration_id"
            class="select select-sm select-bordered"
          >
            <option value="">All Integrations</option>
            <option
              :for={integration <- @integrations}
              value={integration.id}
              selected={to_string(integration.id) == @filter_integration_id}
            >
              {integration.name}
            </option>
          </select>
        </form>

        <div class="join">
          <button
            :for={status <- [:all, :success, :failed, :skipped]}
            class={[
              "join-item btn btn-sm",
              if(@filter_status == status, do: status_btn_active(status), else: "btn-ghost")
            ]}
            phx-click="filter_status"
            phx-value-status={status}
          >
            {humanize(status)}
          </button>
        </div>
      </div>

      <div :if={@logs == []}>
        <.empty_state title="No logs match the current filters" icon="hero-document-text" />
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

  defp status_btn_active(:all), do: "btn-neutral"
  defp status_btn_active(:success), do: "btn-success"
  defp status_btn_active(:failed), do: "btn-error"
  defp status_btn_active(:skipped), do: "btn-warning"
end
