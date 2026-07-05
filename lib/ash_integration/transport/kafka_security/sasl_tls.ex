defmodule AshIntegration.Transport.KafkaSecurity.SaslTls do
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

    # Verify the broker's certificate (chain + hostname) by default. An operator
    # on an internal/firewalled broker with a self-signed or absent cert opts
    # THAT connection out with :verify_none — a stored, visible, per-connection
    # choice, never a global switch.
    attribute :verify, :atom do
      allow_nil? false
      public? true
      default :verify_peer
      constraints one_of: [:verify_peer, :verify_none]
    end

    # Optional inline PEM certificate for a private/self-signed CA. Stored on the
    # connection record itself (a CA cert is not secret, but this is marked
    # sensitive to keep it out of logs/inspect), so a connection is
    # self-contained — no side-channel file on every node. When set it AUGMENTS
    # the OS trust store, so a mix of public-CA and private-CA endpoints verifies.
    attribute :cacert_pem, :string do
      allow_nil? true
      public? true
      sensitive? true
    end

    # Optional server-name override for the TLS handshake — some internal brokers
    # front a certificate whose CN differs from the broker address.
    attribute :sni, :string do
      allow_nil? true
      public? true
    end
  end

  validations do
    validate {AshIntegration.Transport.Validations.RequireEncryptedArgument, field: :password}
    validate AshIntegration.Transport.Validations.CacertPem
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
