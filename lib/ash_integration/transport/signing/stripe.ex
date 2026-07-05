defmodule AshIntegration.Transport.Signing.Stripe do
  @vault Application.compile_env!(:ash_integration, :vault)

  @moduledoc """
  The `stripe` built-in signing scheme — native, no sandbox.

  Signs `"<unix_seconds>.<body>"` with HMAC-SHA256 and emits a single
  `t=<ts>,v1=<hex>` header (the Stripe webhook format). `header_name` defaults to
  `stripe-signature` and is lowercased on the wire (`Signing.compute/2`), so any
  casing an operator types still de-dups cleanly against transform-set headers.
  The `secret` is `ash_cloak`-encrypted.
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
    attribute :header_name, :string do
      allow_nil? false
      public? true
      default "stripe-signature"
    end

    attribute :secret, :string do
      allow_nil? true
      public? true
      sensitive? true
    end
  end

  validations do
    validate {AshIntegration.Transport.Validations.RequireEncryptedArgument, field: :secret}
    validate {AshIntegration.Transport.Validations.HeaderName, field: :header_name}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
