defmodule Example.Integration.OutboundIntegrationLog do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.OutboundIntegrationLogResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_integration_logs"
    repo Example.Repo
  end

  resource do
    plural_name :outbound_integration_logs
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
