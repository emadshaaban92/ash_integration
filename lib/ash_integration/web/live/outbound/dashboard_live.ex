defmodule AshIntegration.Web.Outbound.DashboardLive do
  @moduledoc false
  use AshIntegration.Web, :live_view

  require Ash.Query
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Integrations") |> load_stats()}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  defp load_stats(socket) do
    actor = socket.assigns.current_user
    sub = AshIntegration.subscription_resource()
    conn = AshIntegration.connection_resource()
    delivery = AshIntegration.event_delivery_resource()
    log = AshIntegration.delivery_log_resource()
    since = DateTime.add(DateTime.utc_now(), -24, :hour)

    assign(socket,
      can_new_subscription: AshIntegration.Web.Outbound.Helpers.can?({sub, :create}, actor),
      stats: %{
        total_subscriptions: count(sub, actor),
        active_subscriptions: count(Ash.Query.filter(sub, active == true), actor),
        failing_subscriptions: count(Ash.Query.filter(sub, suspended == true), actor),
        total_connections: count(conn, actor),
        total_event_types: map_size(AshIntegration.Outbound.Declare.Registry.catalog()),
        delivered_24h:
          count(Ash.Query.filter(log, status == :success and created_at >= ^since), actor),
        suppressed_24h:
          count(Ash.Query.filter(log, status == :suppressed and created_at >= ^since), actor),
        # Parked is a STANDING backlog, not a 24h window: a build failure (broken
        # transform/producer) parks deliveries that sit until reprocess. Counts the
        # current `:parked` rows — the blind spot this view used to miss entirely.
        parked: count(Ash.Query.filter(delivery, state == :parked), actor),
        # Terminal is the delivery-side standing backlog: `:failed` rows with a
        # terminal verdict (`:permanent`/`:expired`) — never retried, each blocking
        # its lane until an operator retries or cancels it.
        terminal:
          count(
            Ash.Query.filter(delivery, state == :failed and not is_nil(terminal_reason)),
            actor
          )
      }
    )
  end

  # No-bang count, authorized as the current user. A failure is logged and
  # surfaced as "—" rather than a misleading 0.
  defp count(query, actor) do
    case Ash.count(query, actor: actor) do
      {:ok, n} ->
        n

      {:error, error} ->
        Logger.warning("Dashboard stat count failed: #{Exception.message(error)}")
        nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:dashboard} />

      <.page_header>
        Integrations
        <:actions>
          <.link
            :if={@can_new_subscription}
            navigate={path(:new_subscription)}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus-mini" /> New Subscription
          </.link>
        </:actions>
      </.page_header>

      <%!-- Every tile is a drill-down: clicking it opens the list view filtered to exactly
    the rows the number counts. The error tiles (Failing / Parked / Terminal) are the
    ones an operator most needs to act on, so they must be reachable in one click. --%>
      <div class="stats stats-vertical sm:stats-horizontal shadow w-full mb-8">
        <.stat_link href={path(:subscriptions)} title="Subscriptions">
          <:value>{stat(@stats.total_subscriptions)}</:value>
          <:desc>{stat(@stats.active_subscriptions)} active</:desc>
        </.stat_link>

        <.stat_link href={path(:failing)} title="Failing" error={pos?(@stats.failing_subscriptions)}>
          <:value>{stat(@stats.failing_subscriptions)}</:value>
          <:desc>suspended subscriptions — click to review</:desc>
        </.stat_link>

        <.stat_link href={path(:delivered)} title="Delivered (24h)">
          <:value>{stat(@stats.delivered_24h)}</:value>
          <:desc>bytes-on-the-wire deliveries in the last 24h</:desc>
        </.stat_link>

        <.stat_link href={path(:suppressed)} title="Suppressed (24h)">
          <:value>{stat(@stats.suppressed_24h)}</:value>
          <:desc>unchanged deliveries withheld (not sent)</:desc>
        </.stat_link>

        <.stat_link href={path(:parked)} title="Parked" error={pos?(@stats.parked)}>
          <:value>{stat(@stats.parked)}</:value>
          <:desc>build failures awaiting reprocess (broken transform)</:desc>
        </.stat_link>

        <.stat_link href={path(:terminal)} title="Terminal" error={pos?(@stats.terminal)}>
          <:value>{stat(@stats.terminal)}</:value>
          <:desc>given-up deliveries blocking their lanes (retry or cancel)</:desc>
        </.stat_link>

        <.stat_link href={path(:connections)} title="Connections">
          <:value>{stat(@stats.total_connections)}</:value>
          <:desc>transport + auth configs</:desc>
        </.stat_link>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.nav_card
          title="Subscriptions"
          description="Event routes — what events to watch and how to transform + deliver them."
          icon="hero-paper-airplane"
          href={path(:subscriptions)}
          count={@stats.total_subscriptions}
        />
        <.nav_card
          title="Event Types"
          description="The derived contract — the event types your system produces, and who produces them."
          icon="hero-bolt"
          href={path(:event_types)}
          count={@stats.total_event_types}
        />
        <.nav_card
          title="Connections"
          description="Reusable transport configs — HTTP endpoints, Kafka brokers, auth and signing."
          icon="hero-link"
          href={path(:connections)}
          count={@stats.total_connections}
        />
        <.nav_card
          title="Events"
          description="The immutable facts — the transactional outbox. One row per captured change."
          icon="hero-queue-list"
          href={path(:events)}
          count={nil}
        />
        <.nav_card
          title="Deliveries"
          description="The per-subscription delivery state machine — browse, filter, and reprocess."
          icon="hero-arrow-path"
          href={path(:deliveries)}
          count={nil}
        />
        <.nav_card
          title="Delivery Logs"
          description="Every delivery attempt — filter by status, connection, or event type."
          icon="hero-clipboard-document-list"
          href={path(:logs)}
          count={nil}
        />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, required: true
  attr :href, :string, required: true
  attr :count, :any, default: nil

  defp nav_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="card card-border border-base-300 hover:border-primary transition-colors cursor-pointer"
    >
      <div class="card-body">
        <div class="flex items-start gap-3">
          <div class="bg-base-200 rounded-box p-2 mt-0.5">
            <.icon name={@icon} class="w-5 h-5" />
          </div>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <h3 class="card-title text-base">{@title}</h3>
              <span :if={is_integer(@count)} class="badge badge-sm badge-ghost">{@count}</span>
            </div>
            <p class="text-sm text-base-content/60 mt-1">{@description}</p>
          </div>
          <.icon name="hero-chevron-right-mini" class="text-base-content/30 mt-1 shrink-0" />
        </div>
      </div>
    </.link>
    """
  end

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :error, :boolean, default: false
  slot :value, required: true
  slot :desc

  # A dashboard stat rendered as a one-click drill-down into its filtered list view.
  defp stat_link(assigns) do
    ~H"""
    <.link navigate={@href} class="stat hover:bg-base-200 transition-colors cursor-pointer">
      <div class="stat-figure text-base-content/30">
        <.icon name="hero-arrow-right-mini" class="size-4" />
      </div>
      <div class="stat-title">{@title}</div>
      <div class={["stat-value", @error && "text-error"]}>{render_slot(@value)}</div>
      <div :if={@desc != []} class="stat-desc">{render_slot(@desc)}</div>
    </.link>
    """
  end

  # A failed (nil) count shows "—"; a real 0 shows 0.
  defp stat(nil), do: "—"
  defp stat(n), do: n

  defp pos?(n) when is_integer(n), do: n > 0
  defp pos?(_), do: false

  defp path(:subscriptions), do: base() <> "/subscriptions"
  defp path(:event_types), do: base() <> "/event-types"
  defp path(:connections), do: base() <> "/connections"
  defp path(:events), do: base() <> "/events"
  defp path(:deliveries), do: base() <> "/deliveries"
  defp path(:logs), do: base() <> "/logs"
  defp path(:new_subscription), do: base() <> "/subscriptions/new"
  # Error-stat drill-downs — each lands on the list filtered to exactly what it counts.
  defp path(:failing), do: base() <> "/subscriptions?suspended=true"
  defp path(:parked), do: base() <> "/deliveries?state=parked"
  defp path(:terminal), do: base() <> "/deliveries?state=terminal"
  # The `since=24h` param time-boxes the Logs list to the same 24h window these tiles
  # count (`created_at >= now-24h`), so the drill-down's rows match the tile's number.
  defp path(:delivered), do: base() <> "/logs?status=success&since=24h"
  defp path(:suppressed), do: base() <> "/logs?status=suppressed&since=24h"

  defp base, do: AshIntegration.Web.base_path()
end
