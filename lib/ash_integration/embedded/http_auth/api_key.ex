defmodule AshIntegration.HttpAuth.ApiKey do
  @vault Application.compile_env(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:value]
    decrypt_by_default []
  end

  attributes do
    attribute :header_name, :string do
      allow_nil? false
      public? true
      default "X-API-Key"
    end

    attribute :value, :string do
      allow_nil? false
      public? true
      sensitive? true
    end
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
