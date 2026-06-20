defmodule AshIntegration.Web.Outbound.SubscriptionLive.Show do
  @moduledoc false
  # The first-class Subscription detail page — the primary work object.
  # It owns everything that defines a route:
  # the (event_type, version) contract, the connection it rides, the delivery
  # route, the Lua transform (+ a live Test), its health (active/suspended/
  # failures), and a window onto its recent deliveries. Editing happens here, not
  # on the connection page.
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.Outbound.DeliveryLive.Helpers, as: DeliveryHelpers
  alias AshIntegration.Web.Outbound.Helpers
  alias AshIntegration.Web.Outbound.SubscriptionLive.FormComponent

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, test_result: nil)}

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, action, %{"id" => id}) when action in [:show, :edit] do
    load_subscription(socket, id)
  end

  defp load_subscription(socket, id) do
    actor = socket.assigns.current_user

    case Ash.get(AshIntegration.subscription_resource(), id,
           actor: actor,
           load: [:connection, :parked_count, :oldest_parked_at]
         ) do
      {:ok, subscription} ->
        socket
        |> assign(subscription: subscription, page_title: subscription.event_type)
        |> assign(perms: perms(subscription, actor))
        |> load_recent_deliveries(subscription)

      {:error, _} ->
        socket
        |> put_flash(:error, "Subscription not found")
        |> push_navigate(to: path(:index))
    end
  end

  defp load_recent_deliveries(socket, subscription) do
    actor = socket.assigns.current_user

    deliveries =
      case AshIntegration.event_delivery_resource()
           |> Ash.Query.for_read(:for_subscription, %{subscription_id: subscription.id},
             actor: actor
           )
           |> Ash.read(actor: actor, page: [limit: 10, count: false]) do
        {:ok, %{results: results}} -> results
        {:ok, results} when is_list(results) -> results
        _ -> []
      end

    assign(socket, recent_deliveries: deliveries)
  end

  @impl true
  def handle_event("test", _params, socket) do
    actor = socket.assigns.current_user

    case AshIntegration.Outbound.Delivery.Transform.Preview.run(
           socket.assigns.subscription.id,
           actor
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(test_result: result)
         |> put_flash(test_level(result.outcome), test_message(result))}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not run the transform preview")}
    end
  end

  def handle_event("delete", _params, socket) do
    actor = socket.assigns.current_user

    case Ash.destroy(socket.assigns.subscription, actor: actor) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "Subscription deleted") |> push_navigate(to: path(:index))}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to delete subscription")}
    end
  end

  def handle_event("health", %{"action" => action}, socket)
      when action in ~w(activate deactivate suspend unsuspend) do
    actor = socket.assigns.current_user
    action_atom = String.to_existing_atom(action)

    socket.assigns.subscription
    |> Ash.Changeset.for_update(action_atom, %{}, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscription #{humanized_health(action)}")
         |> load_subscription(socket.assigns.subscription.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Action failed")}
    end
  end

  @impl true
  def handle_info({FormComponent, {:saved, _record}}, socket), do: {:noreply, socket}

  defp humanized_health("activate"), do: "activated"
  defp humanized_health("deactivate"), do: "deactivated"
  defp humanized_health("suspend"), do: "suspended"
  defp humanized_health("unsuspend"), do: "unsuspended"

  defp test_level(:error), do: :error
  defp test_level(_), do: :info

  defp test_message(%{outcome: :ok}), do: "Transform ran — output below"

  defp test_message(%{outcome: :skipped}),
    do: "Transform skipped this event (would not be delivered)"

  defp test_message(%{outcome: :error, error: error}), do: "Transform error: #{error}"

  defp test_badge_class(:ok), do: "badge-success"
  defp test_badge_class(:skipped), do: "badge-ghost"
  defp test_badge_class(_), do: "badge-error"

  defp test_label(:ok), do: "transformed"
  defp test_label(outcome), do: to_string(outcome)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:subscriptions} />

      <div class="breadcrumbs text-sm mb-2">
        <ul>
          <li><.link navigate={path(:index)}>Subscriptions</.link></li>
          <li>{@subscription.event_type}</li>
        </ul>
      </div>

      <.page_header>
        {@subscription.event_type}
        <span class="text-base-content/50 text-base">v{@subscription.version}</span>
        <:subtitle>
          <.active_badge active={@subscription.active} />
          <span :if={@subscription.suspended} class="badge badge-sm badge-error gap-1 ml-1">
            <.icon name="hero-pause-mini" class="size-3" /> Suspended
          </span>
          <span class="ml-1"><DeliveryHelpers.health_badge record={@subscription} /></span>
        </:subtitle>
        <:actions>
          <button class="btn btn-ghost btn-sm" phx-click="test">
            <.icon name="hero-beaker-mini" /> Test transform
          </button>
          <.link
            :if={@perms.update}
            patch={path(:edit, @subscription.id)}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-pencil-square-mini" /> Edit
          </.link>
          <button
            :if={@perms.destroy}
            class="btn btn-ghost btn-sm text-error"
            phx-click="delete"
            data-confirm="Delete this subscription?"
          >
            Delete
          </button>
        </:actions>
      </.page_header>

      <div class="card card-border border-base-300 p-4 mb-4">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
          <.field label="Event Type" mono>{@subscription.event_type}</.field>
          <.field label="Version">v{@subscription.version}</.field>
          <.field label="Connection">
            <.link
              navigate={base() <> "/connections/#{@subscription.connection_id}"}
              class="link link-hover"
            >
              {@subscription.connection && @subscription.connection.name}
            </.link>
          </.field>
          <.field label="Delivery">
            {route_summary(@subscription.route_config)}
          </.field>
          <.field label="Coalescing">
            {if @subscription.notify_on_every_change, do: "Every change", else: "Latest state only"}
          </.field>
          <.field label="Suppress unchanged">
            {if @subscription.suppress_unchanged,
              do: "On — identical bodies withheld",
              else: "Off"}
          </.field>
        </div>
      </div>

      <div class="card card-border border-base-300 p-4 mb-4">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div class="flex items-center gap-6 text-sm">
            <div>
              <div class="text-base-content/50">Suspended</div>
              <div class={[
                "font-medium",
                @subscription.suspended && "text-warning"
              ]}>
                {if @subscription.suspended, do: "Suspended", else: "Active"}
              </div>
            </div>
            <div>
              <div class="text-base-content/50">Parked deliveries</div>
              <div class={["font-medium", @subscription.parked_count > 0 && "text-error"]}>
                {@subscription.parked_count}
                <span :if={@subscription.oldest_parked_at} class="text-base-content/50 font-normal">
                  (oldest {Helpers.format_datetime(@subscription.oldest_parked_at)})
                </span>
              </div>
            </div>
            <div :if={@subscription.suspended}>
              <div class="text-base-content/50">Suspension reason</div>
              <div class="font-medium">{@subscription.suspension_reason || "—"}</div>
            </div>
          </div>
          <div class="flex gap-2">
            <button
              :if={@subscription.active and @perms.deactivate}
              class="btn btn-ghost btn-sm"
              phx-click="health"
              phx-value-action="deactivate"
            >
              Deactivate
            </button>
            <button
              :if={!@subscription.active and @perms.activate}
              class="btn btn-ghost btn-sm"
              phx-click="health"
              phx-value-action="activate"
            >
              Activate
            </button>
            <button
              :if={@subscription.suspended and @perms.unsuspend}
              class="btn btn-warning btn-sm"
              phx-click="health"
              phx-value-action="unsuspend"
            >
              Unsuspend
            </button>
            <button
              :if={!@subscription.suspended and @perms.suspend}
              class="btn btn-ghost btn-sm"
              phx-click="health"
              phx-value-action="suspend"
            >
              Suspend
            </button>
          </div>
        </div>
      </div>

      <div class="card card-border border-base-300 p-4 mb-4">
        <h3 class="font-semibold mb-2">Transform</h3>
        <div :if={blank?(@subscription.transform_source)} class="text-sm text-base-content/50">
          No transform — delivers the resolved route defaults unchanged.
        </div>
        <pre
          :if={!blank?(@subscription.transform_source)}
          class="bg-base-200 rounded-box p-3 text-xs overflow-x-auto"
        ><code>{@subscription.transform_source}</code></pre>
      </div>

      <div :if={@test_result} class="card card-border border-base-300 p-4 mb-4">
        <div class="flex items-center gap-2 mb-3">
          <h3 class="font-semibold">Transform test</h3>
          <span class={["badge badge-sm", test_badge_class(@test_result.outcome)]}>
            {test_label(@test_result.outcome)}
          </span>
          <span class="text-sm text-base-content/60">
            {if @test_result.source[:real?],
              do: "sampled from #{@test_result.source.resource} #{@test_result.source.resource_id}",
              else: "static sample"}
          </span>
        </div>

        <div :if={@test_result[:error]} class="alert alert-error mb-3">
          <.icon name="hero-exclamation-triangle" />
          <span class="font-mono text-sm">{@test_result.error}</span>
        </div>

        <.test_json title="Transform input (sample event)" data={@test_result.input} />
        <.test_json
          :if={@test_result.output}
          title="Transform output (resolved descriptor; signature + auth added live)"
          data={@test_result.output}
        />
      </div>

      <div class="flex items-center justify-between mb-2">
        <h3 class="font-semibold">Recent deliveries</h3>
        <div class="flex gap-2">
          <.link navigate={path(:deliveries, @subscription.id)} class="btn btn-ghost btn-xs">
            All deliveries
          </.link>
          <.link navigate={path(:logs, @subscription.id)} class="btn btn-ghost btn-xs">
            Logs
          </.link>
        </div>
      </div>
      <div :if={@recent_deliveries == []} class="text-sm text-base-content/50">
        No deliveries yet.
      </div>
      <table :if={@recent_deliveries != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Key</th>
            <th>State</th>
            <th>Attempts</th>
            <th>Created</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={delivery <- @recent_deliveries}>
            <td class="font-mono text-xs">{delivery.event_key}</td>
            <td><DeliveryHelpers.state_badge delivery={delivery} /></td>
            <td>{delivery.attempts}</td>
            <td class="text-sm text-base-content/60">
              {Helpers.format_datetime(delivery.created_at)}
            </td>
            <td class="text-right">
              <.link navigate={base() <> "/deliveries/#{delivery.id}"} class="btn btn-ghost btn-xs">
                View
              </.link>
            </td>
          </tr>
        </tbody>
      </table>

      <.modal
        :if={@live_action == :edit}
        id="subscription-modal"
        show
        on_cancel={JS.navigate(path(:show, @subscription.id))}
      >
        <h3 class="text-lg font-bold mb-4">Edit Subscription</h3>
        <.live_component
          module={FormComponent}
          id="subscription-form"
          action={:edit_subscription}
          connection={@subscription.connection}
          subscription={@subscription}
          actor={@current_user}
          navigate={path(:show, @subscription.id)}
        />
      </.modal>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :data, :any, required: true

  defp test_json(assigns) do
    ~H"""
    <div class="mb-3">
      <div class="text-sm font-medium mb-1">{@title}</div>
      <pre class="bg-base-200 rounded-box p-3 text-xs overflow-x-auto"><code>{Jason.encode!(@data, pretty: true)}</code></pre>
    </div>
    """
  end

  defp perms(sub, actor) do
    %{
      update: Helpers.can?({sub, :update}, actor),
      destroy: Helpers.can?({sub, :destroy}, actor),
      activate: Helpers.can?({sub, :activate}, actor),
      deactivate: Helpers.can?({sub, :deactivate}, actor),
      suspend: Helpers.can?({sub, :suspend}, actor),
      unsuspend: Helpers.can?({sub, :unsuspend}, actor)
    }
  end

  defp route_summary(%Ash.Union{type: :http, value: route}) do
    method = (route.method && route.method |> to_string() |> String.upcase()) || "POST"
    path = route.path || "(base URL)"
    "HTTP #{method} #{path}"
  end

  defp route_summary(%Ash.Union{type: :kafka, value: route}),
    do: "Kafka topic #{route.topic || "(default)"}"

  defp route_summary(_), do: "Route defaults"

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp path(:index), do: base() <> "/subscriptions"
  defp path(:show, id), do: base() <> "/subscriptions/#{id}"
  defp path(:edit, id), do: base() <> "/subscriptions/#{id}/edit"
  defp path(:deliveries, id), do: base() <> "/deliveries?subscription=#{id}"
  defp path(:logs, id), do: base() <> "/logs?subscription=#{id}"
  defp base, do: AshIntegration.Web.base_path()
end
