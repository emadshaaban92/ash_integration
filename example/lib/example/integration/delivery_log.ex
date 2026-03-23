defmodule Example.Integration.DeliveryLog do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.DeliveryLogResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "integration_delivery_logs"
    repo Example.Repo
  end

  resource do
    plural_name :delivery_logs
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
