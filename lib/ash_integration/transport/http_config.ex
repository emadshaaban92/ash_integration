defmodule AshIntegration.Transport.HttpConfig do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    # Connection-level base URL (scheme + host, optionally a base path). The
    # per-event-type route — the path joined onto this, and the HTTP method —
    # lives on the subscription and is resolved at delivery time.
    attribute :base_url, :string do
      allow_nil? false
      public? true
    end

    attribute :auth, :union do
      allow_nil? false
      public? true
      default %{type: "none"}

      constraints types: [
                    none: [
                      type: AshIntegration.Transport.HttpAuth.None,
                      tag: :type,
                      tag_value: "none"
                    ],
                    bearer_token: [
                      type: AshIntegration.Transport.HttpAuth.BearerToken,
                      tag: :type,
                      tag_value: "bearer_token"
                    ],
                    api_key: [
                      type: AshIntegration.Transport.HttpAuth.ApiKey,
                      tag: :type,
                      tag_value: "api_key"
                    ],
                    basic_auth: [
                      type: AshIntegration.Transport.HttpAuth.BasicAuth,
                      tag: :type,
                      tag_value: "basic_auth"
                    ],
                    oauth2_client_credentials: [
                      type: AshIntegration.Transport.OAuth2.ClientCredentials,
                      tag: :type,
                      tag_value: "oauth2_client_credentials"
                    ]
                  ],
                  storage: :map_with_tag
    end

    # Connection-level default request timeout. A subscription may override it.
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

    # Explicit signing scheme (none/stripe/custom). The chosen variant carries its
    # own encrypted secret, so "a secret with no scheme" is unrepresentable. See
    # `AshIntegration.Transport.SigningScheme`.
    attribute :signing, AshIntegration.Transport.SigningScheme do
      allow_nil? false
      public? true
      default %{type: "none"}
    end
  end

  validations do
    validate match(:base_url, ~r/\Ahttps?:\/\/.+/),
      message: "must be a valid HTTP or HTTPS URL"

    validate {AshIntegration.Transport.Validations.HttpTimeout, []}
  end

  changes do
    # Store header names lowercase so they can't collide case-insensitively with
    # the library's wire headers or a transform override at delivery.
    change AshIntegration.Transport.Changes.DowncaseHeaderKeys
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
