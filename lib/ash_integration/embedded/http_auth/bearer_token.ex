defmodule AshIntegration.HttpAuth.BearerToken do
  @vault Application.compile_env!(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:token]
    decrypt_by_default []
  end

  attributes do
    attribute :token, :string do
      allow_nil? true
      public? true
      sensitive? true
    end
  end

  validations do
    validate {AshIntegration.Validations.RequireEncryptedArgument, field: :token}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
