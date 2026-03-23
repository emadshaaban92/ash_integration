defmodule AshIntegration.Web do
  def base_path do
    Application.get_env(:ash_integration, :base_path, "/integrations")
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      import AshIntegration.Web.Components
      import Phoenix.HTML

      alias Phoenix.LiveView.JS
      alias AshIntegration.OutboundIntegrations.Info, as: OutboundInfo

      unquote(helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      import AshIntegration.Web.Components
      import Phoenix.HTML

      alias AshIntegration.OutboundIntegrations.Info, as: OutboundInfo

      unquote(helpers())
    end
  end

  defp helpers do
    quote do
      defdelegate humanize(value), to: AshIntegration.Web.OutboundIntegrationLive.Helpers
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
