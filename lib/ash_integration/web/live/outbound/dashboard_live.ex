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
        parked: count(Ash.Query.filter(delivery, state == :parked), actor)
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

      <div class="stats stats-vertical sm:stats-horizontal shadow w-full mb-8">
        <div class="stat">
          <div class="stat-title">Subscriptions</div>
          <div class="stat-value">{stat(@stats.total_subscriptions)}</div>
          <div class="stat-desc">{stat(@stats.active_subscriptions)} active</div>
        </div>

        <div class="stat">
          <div class="stat-title">Failing</div>
          <div class={["stat-value", pos?(@stats.failing_subscriptions) && "text-error"]}>
            {stat(@stats.failing_subscriptions)}
          </div>
          <div class="stat-desc">subscriptions with consecutive failures</div>
        </div>

        <div class="stat">
          <div class="stat-title">Delivered (24h)</div>
          <div class="stat-value">{stat(@stats.delivered_24h)}</div>
          <div class="stat-desc">bytes-on-the-wire deliveries in the last 24h</div>
        </div>

        <div class="stat">
          <div class="stat-title">Suppressed (24h)</div>
          <div class="stat-value">{stat(@stats.suppressed_24h)}</div>
          <div class="stat-desc">unchanged deliveries withheld (not sent)</div>
        </div>

        <div class="stat">
          <div class="stat-title">Parked</div>
          <div class={["stat-value", pos?(@stats.parked) && "text-error"]}>
            {stat(@stats.parked)}
          </div>
          <div class="stat-desc">build failures awaiting reprocess (broken transform)</div>
        </div>

        <div class="stat">
          <div class="stat-title">Connections</div>
          <div class="stat-value">{stat(@stats.total_connections)}</div>
          <div class="stat-desc">transport + auth configs</div>
        </div>
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

  defp base, do: AshIntegration.Web.base_path()
end
