defmodule Example.Outbound.Event do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Capture.Event],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_events"
    repo Example.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
