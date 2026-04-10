defmodule Example.Integration.OutboundIntegrationEvent do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.OutboundIntegrationEventResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_integration_events"
    repo Example.Repo
  end

  resource do
    plural_name :outbound_integration_events
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
