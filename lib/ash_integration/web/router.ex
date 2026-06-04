defmodule AshIntegration.Web.Router do
  defmacro ash_integration_dashboard(path, _opts \\ []) do
    quote bind_quoted: [path: path] do
      Application.put_env(:ash_integration, :base_path, path)

      scope path, alias: false do
        import Phoenix.LiveView.Router, only: [live: 3, live: 4]

        # Home
        live "/", AshIntegration.Web.Outbound.DashboardLive, :index

        # Subscriptions — primary work object, with a first-class detail page.
        # Static /new before /:id so Phoenix matches it first.
        live "/subscriptions", AshIntegration.Web.Outbound.SubscriptionLive.Index, :index
        live "/subscriptions/new", AshIntegration.Web.Outbound.SubscriptionLive.Index, :new
        live "/subscriptions/:id", AshIntegration.Web.Outbound.SubscriptionLive.Show, :show
        live "/subscriptions/:id/edit", AshIntegration.Web.Outbound.SubscriptionLive.Show, :edit

        # Event Types — the derived contract (the event-first catalog).
        live "/event-types", AshIntegration.Web.Outbound.EventTypeLive.Index, :index
        live "/event-types/:type", AshIntegration.Web.Outbound.EventTypeLive.Show, :show

        # Connections — secondary; transport/auth/ordering domain.
        live "/connections", AshIntegration.Web.Outbound.ConnectionLive.Index, :index
        live "/connections/new", AshIntegration.Web.Outbound.ConnectionLive.Index, :new
        live "/connections/edit/:id", AshIntegration.Web.Outbound.ConnectionLive.Index, :edit
        live "/connections/:id", AshIntegration.Web.Outbound.ConnectionLive.Show, :show

        live "/connections/:id/subscriptions/new",
             AshIntegration.Web.Outbound.ConnectionLive.Show,
             :new_subscription

        # Events — the immutable fact / transactional outbox (one row per change).
        live "/events", AshIntegration.Web.Outbound.EventLive.All, :index
        live "/events/:id", AshIntegration.Web.Outbound.EventLive.Show, :show

        # Deliveries — the per-subscription EventDelivery state machine.
        live "/deliveries", AshIntegration.Web.Outbound.DeliveryLive.All, :index
        live "/deliveries/:id", AshIntegration.Web.Outbound.DeliveryLive.Show, :show

        # Delivery logs — the per-attempt transport log.
        live "/logs", AshIntegration.Web.Outbound.DeliveryLogLive.All, :index
        live "/logs/:id", AshIntegration.Web.Outbound.DeliveryLogLive.Show, :show
      end
    end
  end
end
