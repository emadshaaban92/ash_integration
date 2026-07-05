defmodule AshIntegration.Transport.OAuth2.ClientCredentials do
  @moduledoc """
  Embedded resource holding a two-legged OAuth2 **client-credentials** grant
  configuration — the machine-to-machine (app-only) flow, deliberately excluding
  the 3-legged authorization-code / consent flow (no browser consent, no
  refresh-token storage, no per-user delegation).

  This is the **shared** schema: the HTTP transport uses it directly as its
  `oauth2_client_credentials` auth variant, and the Email MsGraph adapter embeds
  it — so HTTP and Email do not fork the OAuth2 config or the token provider.

  The `client_secret` is encrypted at rest via AshCloak (exactly like the HTTP
  bearer token / Kafka SASL password), decrypted **live** at delivery through
  `AshIntegration.Transport.Utils.load_secret/3`, and never written into the
  stored `event.delivery` descriptor. Unlike the optional SMTP password it is
  **required** — a client-credentials grant is meaningless without it.
  """
  @vault Application.compile_env!(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:client_secret]
    decrypt_by_default []
  end

  attributes do
    # The token endpoint (the OAuth2 `token_url`). Runs through the SSRF egress
    # gate at save (`classify`) and fetch (`pin`), same as a webhook URL.
    attribute :token_url, :string do
      allow_nil? false
      public? true
    end

    attribute :client_id, :string do
      allow_nil? false
      public? true
    end

    attribute :client_secret, :string do
      allow_nil? true
      public? true
      sensitive? true
    end

    # Space-delimited OAuth2 scopes (e.g. "https://graph.microsoft.com/.default").
    # Sent as the `scope` form param when present.
    attribute :scopes, :string do
      allow_nil? true
      public? true
    end

    # Optional `audience` param (Auth0 and others use it to select the API).
    attribute :audience, :string do
      allow_nil? true
      public? true
    end

    # Arbitrary extra token-request params merged into the POST body (advanced;
    # e.g. `resource` for legacy Azure v1 endpoints). String keys/values.
    attribute :extra_params, :map do
      allow_nil? false
      public? true
      default %{}
    end

    # Token-endpoint client authentication style:
    #   * `:post`  — `client_id`/`client_secret` in the form body (default).
    #   * `:basic` — HTTP Basic `Authorization` header.
    attribute :auth_style, :atom do
      allow_nil? false
      public? true
      default :post
      constraints one_of: [:post, :basic]
    end
  end

  validations do
    validate {AshIntegration.Transport.Validations.RequireEncryptedArgument,
              field: :client_secret}

    validate match(:token_url, ~r/\Ahttps?:\/\/.+/),
      message: "must be a valid HTTP or HTTPS URL"

    validate {AshIntegration.Transport.Validations.EgressUrl, field: :token_url}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
