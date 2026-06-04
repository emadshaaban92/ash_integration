defmodule AshIntegration.Web.Outbound.ConnectionLive.Show do
  @moduledoc false
  # The connection (secondary) detail: transport/auth/ordering-domain config and
  # the list of subscriptions riding it. Subscriptions link out to their own
  # first-class detail page (SubscriptionLive.Show), which owns subscription
  # editing and the transform editor/test. Creating a subscription is offered
  # here, pre-filled with this connection.
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.Outbound.Helpers
  alias AshIntegration.Web.Outbound.SubscriptionLive.FormComponent, as: SubscriptionForm

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         subscriptions: [],
         can_edit: false,
         can_add_subscription: false,
         perms: %{}
       )}

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, action, %{"id" => id}) when action in [:show, :new_subscription] do
    load_connection(socket, id)
  end

  defp load_connection(socket, id) do
    actor = socket.assigns.current_user

    case Ash.get(AshIntegration.connection_resource(), id, actor: actor, load: [:owner]) do
      {:ok, connection} ->
        socket
        |> assign(connection: connection, page_title: connection.name)
        |> assign(
          can_edit: Helpers.can?({connection, :update}, actor),
          can_add_subscription:
            Helpers.can?({AshIntegration.subscription_resource(), :create}, actor)
        )
        |> load_subscriptions(connection)

      {:error, _} ->
        socket
        |> put_flash(:error, "Connection not found")
        |> push_navigate(to: path(:index))
    end
  end

  defp load_subscriptions(socket, connection) do
    actor = socket.assigns.current_user

    subscriptions =
      case AshIntegration.subscription_resource()
           |> Ash.Query.for_read(:for_connection, %{connection_id: connection.id}, actor: actor)
           |> Ash.read(actor: actor) do
        {:ok, results} when is_list(results) -> results
        {:ok, %{results: results}} -> results
        _ -> []
      end

    perms =
      Map.new(subscriptions, fn s -> {s.id, %{destroy: Helpers.can?({s, :destroy}, actor)}} end)

    assign(socket, subscriptions: subscriptions, perms: perms)
  end

  @impl true
  def handle_event("delete-subscription", %{"id" => id}, socket) do
    actor = socket.assigns.current_user
    conn_id = socket.assigns.connection.id

    # Scope to the page's connection — don't act on a subscription belonging to
    # another connection, even one the actor can otherwise read.
    with {:ok, %{connection_id: ^conn_id} = record} <-
           Ash.get(AshIntegration.subscription_resource(), id, actor: actor),
         :ok <- Ash.destroy(record, actor: actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Subscription deleted")
       |> load_subscriptions(socket.assigns.connection)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete subscription")}
    end
  end

  @impl true
  def handle_info({SubscriptionForm, {:saved, _record}}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:connections} />

      <div class="breadcrumbs text-sm mb-2">
        <ul>
          <li><.link navigate={path(:index)}>Connections</.link></li>
          <li>{@connection.name}</li>
        </ul>
      </div>

      <.page_header>
        {@connection.name}
        <:actions>
          <.link navigate={path(:deliveries, @connection.id)} class="btn btn-ghost btn-sm">
            <.icon name="hero-paper-airplane-mini" /> Deliveries
          </.link>
          <.link navigate={path(:logs, @connection.id)} class="btn btn-ghost btn-sm">
            <.icon name="hero-document-text-mini" /> Delivery Logs
          </.link>
          <.link
            :if={@can_edit}
            navigate={path(:edit, @connection.id)}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-pencil-square-mini" /> Edit Connection
          </.link>
          <.link
            :if={@can_add_subscription}
            navigate={path(:new_subscription, @connection.id)}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus-mini" /> Add Subscription
          </.link>
        </:actions>
      </.page_header>

      <div class="card card-border border-base-300 p-4 mb-6">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
          <div>
            <div class="text-base-content/50">Transport</div>
            <div class="font-medium">{humanize(@connection.transport_config.type)}</div>
          </div>
          <div>
            <div class="text-base-content/50">Owner</div>
            <div class="font-medium">{Helpers.owner_name(@connection)}</div>
          </div>
          <div>
            <div class="text-base-content/50">Status</div>
            <div><.active_badge active={@connection.active} /></div>
          </div>
          <div>
            <div class="text-base-content/50">Consecutive Failures</div>
            <div class="font-medium">{@connection.consecutive_failures}</div>
          </div>
        </div>
      </div>

      <h3 class="font-semibold mb-2">Subscriptions</h3>

      <div :if={@subscriptions == []}>
        <.empty_state title="No subscriptions yet">
          <:actions>
            <.link
              :if={@can_add_subscription}
              navigate={path(:new_subscription, @connection.id)}
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-plus-mini" /> Add the first subscription
            </.link>
          </:actions>
        </.empty_state>
      </div>

      <table :if={@subscriptions != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Event Type</th>
            <th>Version</th>
            <th>Every change?</th>
            <th>Status</th>
            <th>Failures</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={sub <- @subscriptions} id={"subscription-#{sub.id}"}>
            <td class="font-medium">
              <.link navigate={path(:subscription, sub.id)} class="link link-hover">
                {sub.event_type}
              </.link>
            </td>
            <td>V{sub.version}</td>
            <td>
              <span :if={sub.notify_on_every_change} class="badge badge-sm badge-info">
                every change
              </span>
              <span :if={!sub.notify_on_every_change} class="text-base-content/50">latest only</span>
            </td>
            <td><.active_badge active={sub.active} /></td>
            <td>
              <span class={[
                "badge badge-sm",
                if(sub.consecutive_failures > 0, do: "badge-warning", else: "badge-ghost")
              ]}>
                {sub.consecutive_failures}
              </span>
            </td>
            <td>
              <div class="flex gap-2 justify-end">
                <.link navigate={path(:subscription, sub.id)} class="btn btn-ghost btn-xs">
                  View
                </.link>
                <button
                  :if={@perms[sub.id][:destroy]}
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete-subscription"
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

      <.modal
        :if={@live_action == :new_subscription}
        id="subscription-modal"
        show
        on_cancel={JS.navigate(path(:show, @connection.id))}
      >
        <h3 class="text-lg font-bold mb-4">Add Subscription</h3>
        <.live_component
          module={SubscriptionForm}
          id="subscription-form"
          action={:new_subscription}
          connection={@connection}
          subscription={nil}
          actor={@current_user}
          navigate={path(:show, @connection.id)}
        />
      </.modal>
    </div>
    """
  end

  defp path(:index), do: base() <> "/connections"
  defp path(:edit, id), do: base() <> "/connections/edit/#{id}"
  defp path(:show, id), do: base() <> "/connections/#{id}"
  defp path(:new_subscription, id), do: base() <> "/connections/#{id}/subscriptions/new"
  defp path(:subscription, id), do: base() <> "/subscriptions/#{id}"
  defp path(:deliveries, id), do: base() <> "/deliveries?connection=#{id}"
  defp path(:logs, id), do: base() <> "/logs?connection=#{id}"

  defp base, do: AshIntegration.Web.base_path()
end
