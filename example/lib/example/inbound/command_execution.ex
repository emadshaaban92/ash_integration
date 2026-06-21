defmodule Example.Inbound.CommandExecution do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Inbound.CommandExecution],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "inbound_command_executions"
    repo Example.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
