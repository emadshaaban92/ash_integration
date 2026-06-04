defmodule AshIntegration.Web.Outbound.DeliveryLive.Show do
  @moduledoc false
  # One EventDelivery: the per-subscription delivery state machine for a single
  # event. Links up to the immutable fact (/events/:id), out to its subscription
  # and connection, and down to its per-attempt delivery logs.
  use AshIntegration.Web, :live_view

  alias AshIntegration.Outbound.Delivery.Reprocessor
  alias AshIntegration.Web.Outbound.DeliveryLive.Helpers, as: DeliveryHelpers
  alias AshIntegration.Web.Outbound.Helpers

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, load_delivery(socket, id)}
  end

  defp load_delivery(socket, id) do
    actor = socket.assigns.current_user

    case Ash.get(AshIntegration.event_delivery_resource(), id,
           actor: actor,
           load: [:subscription, :logs, :connection, :event]
         ) do
      {:ok, delivery} ->
        assign(socket,
          delivery: delivery,
          page_title: delivery.event_type,
          perms: %{
            reprocess: Helpers.can?({delivery, :reprocess}, actor),
            reset: Helpers.can?({delivery, :reset_to_pending}, actor),
            cancel: Helpers.can?({delivery, :cancel}, actor)
          }
        )

      _ ->
        socket
        |> put_flash(:error, "Delivery not found")
        |> push_navigate(to: path(:index))
    end
  end

  @impl true
  def handle_event("reprocess", _params, socket) do
    # Reprocess re-runs project→transform under system authority, so it bypasses
    # the actor's Ash policies — enforce the actor's permission to reprocess here.
    if Helpers.can?({socket.assigns.delivery, :reprocess}, socket.assigns.current_user) do
      do_reprocess(socket)
    else
      {:noreply, put_flash(socket, :error, "Not authorized to reprocess this delivery")}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply, run_action(socket, :reset_to_pending, %{}, "Delivery reset to pending")}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     run_action(socket, :cancel, %{last_error: "Cancelled by operator"}, "Delivery cancelled")}
  end

  defp do_reprocess(socket) do
    case Reprocessor.reprocess_event(socket.assigns.delivery) do
      {:ok, :pending} ->
        {:noreply, reloaded(socket, :info, "Delivery reprocessed and re-queued")}

      {:ok, :cancelled} ->
        {:noreply, reloaded(socket, :info, "Transform skipped — delivery cancelled")}

      {:error, reason} ->
        {:noreply, reloaded(socket, :error, "Still failing: #{inspect(reason)}")}
    end
  end

  defp run_action(socket, action, params, ok_msg) do
    socket.assigns.delivery
    |> Ash.Changeset.for_update(action, params, actor: socket.assigns.current_user)
    |> Ash.update(actor: socket.assigns.current_user)
    |> case do
      {:ok, _} -> reloaded(socket, :info, ok_msg)
      {:error, _} -> put_flash(socket, :error, "Action failed")
    end
  end

  defp reloaded(socket, level, msg) do
    socket
    |> put_flash(level, msg)
    |> load_delivery(socket.assigns.delivery.id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:deliveries} />

      <div class="breadcrumbs text-sm mb-2">
        <ul>
          <li><.link navigate={path(:index)}>Deliveries</.link></li>
          <li>{@delivery.event_type}</li>
        </ul>
      </div>

      <.page_header>
        {@delivery.event_type}
        <span class="text-base-content/50 text-base">v{@delivery.version}</span>
        <:subtitle>
          <DeliveryHelpers.state_badge delivery={@delivery} />
        </:subtitle>
        <:actions>
          <button
            :if={DeliveryHelpers.parked?(@delivery) and @perms.reprocess}
            class="btn btn-warning btn-sm"
            phx-click="reprocess"
          >
            <.icon name="hero-arrow-path-mini" /> Reprocess
          </button>
          <button
            :if={@delivery.state in [:scheduled, :cancelled] and @perms.reset}
            class="btn btn-ghost btn-sm"
            phx-click="reset"
            data-confirm="Reset this delivery back to pending?"
          >
            Reset to pending
          </button>
          <button
            :if={@delivery.state in [:pending, :scheduled] and @perms.cancel}
            class="btn btn-ghost btn-sm text-error"
            phx-click="cancel"
            data-confirm="Cancel this delivery?"
          >
            Cancel
          </button>
        </:actions>
      </.page_header>

      <div class="card card-border border-base-300 p-4 mb-4">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
          <.field label="Event Key" mono>{@delivery.event_key}</.field>
          <.field label="Attempts">{@delivery.attempts}</.field>
          <.field label="Created">{Helpers.format_datetime(@delivery.created_at, :long)}</.field>
          <.field label="Connection">
            <.link
              navigate={base() <> "/connections/#{@delivery.connection_id}"}
              class="link link-hover"
            >
              {@delivery.connection && @delivery.connection.name}
            </.link>
          </.field>
          <.field label="Subscription">
            <.link
              navigate={base() <> "/subscriptions/#{@delivery.subscription_id}"}
              class="link link-hover"
            >
              {@delivery.event_type} v{@delivery.version}
            </.link>
          </.field>
          <.field label="Event (the fact)" mono>
            <.link navigate={base() <> "/events/#{@delivery.event_id}"} class="link link-hover">
              {@delivery.event_id}
            </.link>
          </.field>
          <.field :if={@delivery.event} label="Source">
            {@delivery.event.source_resource} · {@delivery.event.source_action}
          </.field>
          <.field :if={@delivery.event} label="Subject (source id)" mono>
            {@delivery.event.source_resource_id}
          </.field>
        </div>
      </div>

      <div :if={@delivery.last_error} class="alert alert-error mb-4">
        <.icon name="hero-exclamation-triangle" />
        <span class="font-mono text-sm">{@delivery.last_error}</span>
      </div>

      <.json_block
        title="Delivery descriptor (resolved at dispatch; signature + auth added live)"
        data={@delivery.delivery}
      />
      <.json_block
        :if={@delivery.event}
        title="Event data (producer output, pre-transform — the immutable fact)"
        data={@delivery.event.data}
      />
      <.json_block title="Delivery Metadata" data={@delivery.delivery_metadata} />

      <h3 class="font-semibold mt-6 mb-2">Delivery Logs</h3>
      <div :if={@delivery.logs in [[], nil]} class="text-sm text-base-content/50">
        No delivery attempts logged yet.
      </div>
      <table :if={@delivery.logs not in [[], nil]} class="table table-zebra">
        <thead>
          <tr>
            <th>Status</th>
            <th>Response</th>
            <th>Duration</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={log <- @delivery.logs}>
            <td><.status_badge status={log.status} /></td>
            <td class="text-sm">{log.response_status || log.error_message || "—"}</td>
            <td class="text-sm">{log.duration_ms && "#{log.duration_ms} ms"}</td>
            <td class="text-right">
              <.link navigate={base() <> "/logs/#{log.id}"} class="btn btn-ghost btn-xs">View</.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp path(:index), do: base() <> "/deliveries"
  defp base, do: AshIntegration.Web.base_path()
end
