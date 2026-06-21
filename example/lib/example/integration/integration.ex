defmodule Example.Integration do
  use Ash.Domain

  resources do
    resource Example.Outbound.Connection
    resource Example.Outbound.Subscription
    resource Example.Outbound.Event
    resource Example.Outbound.EventDelivery
    resource Example.Outbound.Log
    resource Example.Inbound.CommandExecution
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
