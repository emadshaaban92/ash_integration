defmodule Example.Outbound.Subscription do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.Subscription],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_subscriptions"
    repo Example.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
