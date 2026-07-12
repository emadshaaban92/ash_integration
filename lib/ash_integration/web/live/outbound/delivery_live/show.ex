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
            # `reprocess` gates the parked-reprocess button, which runs under system
            # authority — strict (fail-closed on an indeterminate policy). `reset`/
            # `cancel` drive actor-authorized updates whose real enforcement is the
            # Ash action itself, so their affordance may stay permissive.
            reprocess: Helpers.can_strict?({delivery, :reprocess}, actor),
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
    # the actor's Ash policies — the strict gate here is the only real enforcement
    # (fail-closed on an indeterminate / record-scoped policy).
    if Helpers.can_strict?({socket.assigns.delivery, :reprocess}, socket.assigns.current_user) do
      do_reprocess(socket)
    else
      {:noreply, put_flash(socket, :error, "Not authorized to reprocess this delivery")}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply, run_action(socket, :reset_to_pending, %{}, "Delivery reset to pending")}
  end

  # Operator "retry now" for a `:failed` (waiting-to-retry or terminal) delivery: the
  # cached descriptor is intact, so no rebuild — the plain `:reprocess` action moves it
  # back to `:pending` and clears the lease/backoff/terminal verdict; the scheduler
  # re-promotes it as its lane's head. Distinct from "reprocess" (parked rows), which
  # re-runs project→transform via the Reprocessor.
  def handle_event("retry", _params, socket) do
    {:noreply, run_action(socket, :reprocess, %{}, "Delivery re-queued for retry")}
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
            :if={@delivery.state == :failed and @perms.reprocess}
            class="btn btn-warning btn-sm"
            phx-click="retry"
            data-confirm="Re-queue this delivery for another attempt? Its lane retries it next."
          >
            <.icon name="hero-arrow-path-mini" /> Retry now
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
            :if={@delivery.state in [:pending, :scheduled, :failed] and @perms.cancel}
            class="btn btn-ghost btn-sm text-error"
            phx-click="cancel"
            data-confirm="Cancel this delivery? Skipping it frees its lane for younger events."
          >
            Cancel
          </button>
        </:actions>
      </.page_header>

      <div class="card card-border border-base-300 p-4 mb-4">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
          <.field label="Event Key" mono>{@delivery.event_key}</.field>
          <.field label="Attempts">{@delivery.attempts}</.field>
          <.field
            :if={@delivery.state == :failed and is_nil(@delivery.terminal_reason)}
            label="Next attempt"
          >
            {(@delivery.next_attempt_at && Helpers.format_datetime(@delivery.next_attempt_at, :long)) ||
              "probe-paced (suspended)"}
          </.field>
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
          <.field :if={@delivery.body_hash} label="Body hash (dedup)" mono>
            {String.slice(@delivery.body_hash, 0, 16)}…
          </.field>
        </div>
      </div>

      <div :if={@delivery.terminal_reason} class="alert alert-error mb-4">
        <.icon name="hero-exclamation-triangle" />
        <span class="text-sm">
          <strong>Terminal ({@delivery.terminal_reason})</strong>
          — this delivery is never retried automatically and it blocks its
          <code>(connection, event key)</code>
          lane: younger events for the key wait behind it. <strong>Retry now</strong>
          re-queues it (a <code>permanent</code>
          rejection will usually fail again unless the target changed); <strong>Cancel</strong>
          skips it and frees the lane.
        </span>
      </div>

      <div :if={@delivery.state == :suppressed} class="alert alert-info mb-4">
        <.icon name="hero-no-symbol" />
        <span class="text-sm">
          <strong>Suppressed</strong>
          — the body was identical to the last delivered body for this event key, so
          nothing was sent. The consumer is already up to date; this is not a failure
          and did not touch the connection's health.
        </span>
      </div>

      <%!-- The red alert is for a CURRENT problem only: a delivery still pending/scheduled,
    parked (build-failed), or failed (retrying/terminal). A `:delivered` or `:cancelled`
    row may carry a stale `last_error` from an earlier attempt that a retry later resolved —
    showing that as a red error made a *successful* delivery look broken. Those get their
    own, non-alarming note below; the full attempt history is in the Delivery Logs table. --%>
      <div
        :if={@delivery.last_error && @delivery.state in [:pending, :scheduled, :parked, :failed]}
        class="alert alert-error mb-4"
      >
        <.icon name="hero-exclamation-triangle" />
        <span class="font-mono text-sm">{@delivery.last_error}</span>
      </div>

      <div
        :if={@delivery.state == :delivered && @delivery.last_error}
        class="alert alert-success mb-4"
      >
        <.icon name="hero-check-circle" />
        <span class="text-sm">
          <strong>Delivered</strong>
          — an earlier attempt failed but a retry succeeded, so the consumer is up to date.
          The failed attempt is kept below under <strong>Delivery Logs</strong>; the last error was: <span class="font-mono">{@delivery.last_error}</span>.
        </span>
      </div>

      <div :if={@delivery.state == :cancelled && @delivery.last_error} class="alert mb-4">
        <.icon name="hero-no-symbol" />
        <span class="text-sm">
          <strong>Cancelled</strong> — {@delivery.last_error}
        </span>
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
