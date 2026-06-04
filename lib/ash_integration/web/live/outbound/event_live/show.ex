defmodule AshIntegration.Web.Outbound.EventLive.Show do
  @moduledoc false
  # One immutable Event (the fact) and its fan-out: the EventDeliveries it produced,
  # one per subscription. This is the top of the runtime drill-down
  # (Event → Delivery → Log). A stuck/poison event (undispatched past the attempt
  # ceiling) can be re-dispatched here by an operator once its cause is fixed.
  use AshIntegration.Web, :live_view

  alias AshIntegration.Web.Outbound.DeliveryLive.Helpers, as: DeliveryHelpers
  alias AshIntegration.Web.Outbound.EventLive.Helpers, as: EventHelpers
  alias AshIntegration.Web.Outbound.Helpers

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, load_event(socket, id)}
  end

  defp load_event(socket, id) do
    actor = socket.assigns.current_user

    case Ash.get(AshIntegration.event_resource(), id,
           actor: actor,
           load: [deliveries: [:connection]]
         ) do
      {:ok, event} ->
        assign(socket,
          event: event,
          page_title: event.event_type,
          can_redispatch: Helpers.can?({event, :mark_dispatched}, actor)
        )

      _ ->
        socket
        |> put_flash(:error, "Event not found")
        |> push_navigate(to: path(:index))
    end
  end

  @impl true
  def handle_event("redispatch", _params, socket) do
    event = socket.assigns.event

    if Helpers.can?({event, :mark_dispatched}, socket.assigns.current_user) do
      do_redispatch(socket, event)
    else
      throw_unauthorized(socket)
    end
  end

  defp throw_unauthorized(socket),
    do: {:noreply, put_flash(socket, :error, "Not authorized to re-dispatch this event")}

  # Un-stick the event (reset its bookkeeping); the relay re-claims it on its next
  # poll. The UI gate above is the authz check; the write itself is library-internal.
  defp do_redispatch(socket, event) do
    event
    |> Ash.Changeset.for_update(:reset_dispatch, %{}, authorize?: false)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _event} ->
        {:noreply,
         socket |> put_flash(:info, "Event queued for re-dispatch") |> load_event(event.id)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Re-dispatch failed: #{Exception.message(error)}")}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, max_attempts: max_attempts())

    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:events} />

      <div class="breadcrumbs text-sm mb-2">
        <ul>
          <li><.link navigate={path(:index)}>Events</.link></li>
          <li>{@event.event_type}</li>
        </ul>
      </div>

      <.page_header>
        {@event.event_type} <span class="text-base-content/50 text-base">v{@event.version}</span>
        <:subtitle>
          <EventHelpers.outbox_badge event={@event} max_attempts={@max_attempts} />
        </:subtitle>
        <:actions>
          <button
            :if={EventHelpers.stuck?(@event, @max_attempts) and @can_redispatch}
            class="btn btn-warning btn-sm"
            phx-click="redispatch"
            data-confirm="Re-dispatch this stuck event? Do this only after fixing the underlying cause."
          >
            <.icon name="hero-arrow-path-mini" /> Re-dispatch
          </button>
        </:actions>
      </.page_header>

      <div class="card card-border border-base-300 p-4 mb-4">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
          <.field label="Wire event-id" mono>{@event.id}</.field>
          <.field label="Event Key" mono>{@event.event_key}</.field>
          <.field label="Created">{Helpers.format_datetime(@event.created_at, :long)}</.field>
          <.field label="Dispatched">
            {Helpers.format_datetime(@event.dispatched_at, :long)}
          </.field>
          <.field label="Source">{@event.source_resource} · {@event.source_action}</.field>
          <.field label="Subject (source id)" mono>{@event.source_resource_id}</.field>
          <.field label="Dispatch attempts">{@event.dispatch_attempts}</.field>
        </div>
      </div>

      <div :if={@event.dispatch_error} class="alert alert-error mb-4">
        <.icon name="hero-exclamation-triangle" />
        <span class="font-mono text-sm">{@event.dispatch_error}</span>
      </div>

      <.json_block title="Event data (producer output — the immutable fact)" data={@event.data} />

      <h3 class="font-semibold mt-6 mb-2">
        Fan-out · {length(@event.deliveries)} {if length(@event.deliveries) == 1,
          do: "delivery",
          else: "deliveries"}
      </h3>
      <div :if={@event.deliveries == []} class="text-sm text-base-content/50">
        No deliveries yet — this event is still in the outbox, or no subscription matched.
      </div>
      <table :if={@event.deliveries != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Connection</th>
            <th>State</th>
            <th>Attempts</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={delivery <- @event.deliveries}>
            <td class="text-sm">{delivery.connection && delivery.connection.name}</td>
            <td><DeliveryHelpers.state_badge delivery={delivery} /></td>
            <td>{delivery.attempts}</td>
            <td class="text-right">
              <.link
                navigate={base() <> "/deliveries/#{delivery.id}"}
                class="btn btn-ghost btn-xs"
              >
                View
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp max_attempts, do: AshIntegration.Outbound.Dispatch.Supervisor.max_attempts()

  defp path(:index), do: base() <> "/events"
  defp base, do: AshIntegration.Web.base_path()
end
