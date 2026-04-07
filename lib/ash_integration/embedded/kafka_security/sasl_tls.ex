defmodule AshIntegration.KafkaSecurity.SaslTls do
  @vault Application.compile_env!(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:password]
    decrypt_by_default []
  end

  attributes do
    attribute :mechanism, :atom do
      allow_nil? false
      public? true
      default :plain
      constraints one_of: [:plain, :scram_sha_256, :scram_sha_512]
    end

    attribute :username, :string do
      allow_nil? false
      public? true
    end

    attribute :password, :string do
      allow_nil? true
      public? true
      sensitive? true
    end
  end

  validations do
    validate {AshIntegration.Validations.RequireEncryptedArgument, field: :password}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
