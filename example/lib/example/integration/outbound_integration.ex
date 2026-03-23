defmodule Example.Integration.OutboundIntegration do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.OutboundIntegrationResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_integrations"
    repo Example.Repo
  end

  resource do
    plural_name :outbound_integrations
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
