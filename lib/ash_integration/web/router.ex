defmodule AshIntegration.Web.Router do
  defmacro ash_integration_dashboard(path, _opts \\ []) do
    quote bind_quoted: [path: path] do
      Application.put_env(:ash_integration, :base_path, path)

      scope path, alias: false do
        import Phoenix.LiveView.Router, only: [live: 3, live: 4]

        live "/", AshIntegration.Web.OutboundIntegrationLive.Index, :index
        live "/new", AshIntegration.Web.OutboundIntegrationLive.Index, :new
        live "/edit/:id", AshIntegration.Web.OutboundIntegrationLive.Index, :edit
        live "/:id", AshIntegration.Web.OutboundIntegrationLive.Show, :show
        live "/:id/edit", AshIntegration.Web.OutboundIntegrationLive.Show, :edit
        live "/:id/test", AshIntegration.Web.OutboundIntegrationLive.Show, :test
        live "/:id/events", AshIntegration.Web.OutboundIntegrationEventLive.Index, :index
        live "/events/:event_id", AshIntegration.Web.OutboundIntegrationEventLive.Show, :show
        live "/logs/all", AshIntegration.Web.DeliveryLogLive.Index, :index
        live "/logs/:id", AshIntegration.Web.DeliveryLogLive.Show, :show
      end
    end
  end
end
