defmodule Example.Outbound.Connection do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Connection],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_connections"
    repo Example.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
