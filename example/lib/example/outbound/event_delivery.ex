defmodule Example.Outbound.EventDelivery do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.EventDelivery],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_event_deliveries"
    repo Example.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
