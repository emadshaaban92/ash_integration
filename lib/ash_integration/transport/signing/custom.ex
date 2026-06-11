defmodule AshIntegration.Transport.Signing.Custom do
  @vault Application.compile_env!(:ash_integration, :vault)

  @moduledoc """
  The `custom` signing scheme — a staged signing behaviour authored in the runtime.

  The `source` exposes optional callbacks the library orchestrates at send time,
  applying the cryptographic primitives between the author's pure string-building
  steps (so the `secret` never enters the sandbox):

      content(ctx)         -- string to hash      (default: the wire body)
      string_to_sign(ctx)  -- string to HMAC      (default: "<unix_seconds>.<body>")
      headers(ctx)         -- place signature in headers
      body(ctx)            -- (Model 2) place it in the body
      url(ctx)             -- (Model 2) place it in the URL

  `algorithm` (the MAC/digest primitive) and `encoding` (the signature output) are
  allowlisted, target-uniform config. See `design/configurable-signing.md`.
  """
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:secret]
    decrypt_by_default []
  end

  attributes do
    attribute :secret, :string do
      allow_nil? true
      public? true
      sensitive? true
    end

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :runtime, :atom do
      allow_nil? false
      public? true
      default :lua
      constraints one_of: [:lua]
    end

    attribute :algorithm, :atom do
      allow_nil? false
      public? true
      default :sha256
      constraints one_of: [:sha256, :sha1, :sha512]
    end

    attribute :encoding, :atom do
      allow_nil? false
      public? true
      default :hex
      constraints one_of: [:hex, :base64, :base64url]
    end
  end

  validations do
    validate {AshIntegration.Transport.Validations.RequireEncryptedArgument, field: :secret}
    validate {AshIntegration.Transport.Validations.SigningSource, []}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
