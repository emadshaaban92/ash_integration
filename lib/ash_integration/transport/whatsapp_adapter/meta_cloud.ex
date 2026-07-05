defmodule AshIntegration.Transport.WhatsAppAdapter.MetaCloud do
  @vault Application.compile_env!(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:access_token]
    decrypt_by_default []
  end

  attributes do
    # The WhatsApp Business phone number ID (a numeric string from Meta Business
    # Manager). It is the path segment of the send endpoint:
    # `POST /<api_version>/<phone_number_id>/messages`. Constrained to bare digits
    # so a value carrying CR/LF or a space can't be interpolated into the Graph URL
    # (which would make Req/Mint raise while building the request target at send).
    attribute :phone_number_id, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9]+\z/
    end

    # The permanent/system-user access token authorizing sends for this WABA.
    # Encrypted at rest (AshCloak) exactly like an HTTP bearer token or a Kafka
    # SASL password, and decrypted **live at delivery** — never stored in the wire
    # descriptor and never logged.
    attribute :access_token, :string do
      allow_nil? true
      public? true
      sensitive? true
    end

    # The Graph API version to target, e.g. `v21.0`. Configurable because Meta
    # ships a new version regularly and deprecates old ones; a connection pins the
    # version it was built against. Constrained to the `v<major>.<minor>` shape so
    # a stray CR/LF or space can't be interpolated into the Graph URL and crash the
    # send while building the request target.
    attribute :api_version, :string do
      allow_nil? false
      public? true
      default "v21.0"
      constraints match: ~r/\Av[0-9]+\.[0-9]+\z/
    end

    # Optional WhatsApp Business Account ID. Not needed to send a message (the
    # phone number ID is), but kept alongside the credential for operators who
    # reference it, and reserved for future WABA-scoped calls.
    attribute :business_account_id, :string do
      allow_nil? true
      public? true
    end
  end

  validations do
    validate {AshIntegration.Transport.Validations.RequireEncryptedArgument, field: :access_token}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
