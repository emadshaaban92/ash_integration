defmodule Example.Integration do
  use Ash.Domain

  resources do
    resource Example.Integration.OutboundIntegration
    resource Example.Integration.OutboundIntegrationLog
    resource Example.Integration.OutboundIntegrationEvent
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
