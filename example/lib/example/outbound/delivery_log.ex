defmodule Example.Outbound.Log do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.Log],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_delivery_logs"
    repo Example.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
