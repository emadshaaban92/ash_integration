defmodule AshIntegration.GrpcSecurity.MutualTls do
  @vault Application.compile_env(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:client_cert_pem, :client_key_pem]
    decrypt_by_default []
  end

  attributes do
    attribute :client_cert_pem, :string do
      allow_nil? true
      public? true
      sensitive? true
    end

    attribute :client_key_pem, :string do
      allow_nil? true
      public? true
      sensitive? true
    end
  end

  validations do
    validate {AshIntegration.Validations.RequireEncryptedArgument, field: :client_cert_pem}
    validate {AshIntegration.Validations.RequireEncryptedArgument, field: :client_key_pem}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
