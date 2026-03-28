defmodule AshIntegration.HttpConfig do
  @vault Application.compile_env(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:signing_secret]
    decrypt_by_default []
  end

  attributes do
    attribute :url, :string do
      allow_nil? false
      public? true
    end

    attribute :auth, :union do
      allow_nil? false
      public? true
      default %{type: "none"}

      constraints types: [
                    none: [
                      type: AshIntegration.HttpAuth.None,
                      tag: :type,
                      tag_value: "none"
                    ],
                    bearer_token: [
                      type: AshIntegration.HttpAuth.BearerToken,
                      tag: :type,
                      tag_value: "bearer_token"
                    ],
                    api_key: [
                      type: AshIntegration.HttpAuth.ApiKey,
                      tag: :type,
                      tag_value: "api_key"
                    ],
                    basic_auth: [
                      type: AshIntegration.HttpAuth.BasicAuth,
                      tag: :type,
                      tag_value: "basic_auth"
                    ]
                  ],
                  storage: :map_with_tag
    end

    attribute :timeout_ms, :integer do
      allow_nil? false
      public? true
      default 30_000
      constraints min: 1000
    end

    attribute :headers, :map do
      public? true
      default %{}
    end

    attribute :method, :atom do
      allow_nil? false
      public? true
      default :post
      constraints one_of: [:post, :put, :patch, :delete]
    end

    attribute :signing_secret, :string do
      public? true
      sensitive? true
    end
  end

  validations do
    validate match(:url, ~r/\Ahttps?:\/\/.+/),
      message: "must be a valid HTTP or HTTPS URL"

    validate {AshIntegration.Validations.HttpTimeout, []}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
