defmodule Example.Accounts.Token do
  use Ash.Resource,
    otp_app: :example,
    domain: Example.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "tokens"
    repo Example.Repo
  end

  actions do
    defaults [:read]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
