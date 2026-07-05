defmodule AshIntegration.Transport.EmailAdapter.Smtp do
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
    # SMTP relay host. Every provider (SES, SendGrid, Postmark, Mailgun, Gmail,
    # O365, an internal Postfix) exposes one, which is what makes the single SMTP
    # adapter a universal target.
    attribute :relay, :string do
      allow_nil? false
      public? true
    end

    attribute :port, :integer do
      allow_nil? false
      public? true
      default 587
      constraints min: 1, max: 65_535
    end

    attribute :username, :string do
      allow_nil? true
      public? true
    end

    # Optional: an open/internal relay may not require auth. When set it is
    # encrypted at rest (AshCloak) exactly like a bearer token or SASL password.
    attribute :password, :string do
      allow_nil? true
      public? true
      sensitive? true
    end

    # Implicit TLS on connect (SMTPS, typically port 465). Distinct from STARTTLS
    # (`tls`), which upgrades a plaintext connection.
    attribute :ssl, :boolean do
      allow_nil? false
      public? true
      default false
    end

    # STARTTLS negotiation, passed straight to gen_smtp.
    attribute :tls, :atom do
      allow_nil? false
      public? true
      default :if_available
      constraints one_of: [:always, :never, :if_available]
    end

    attribute :auth, :atom do
      allow_nil? false
      public? true
      default :if_available
      constraints one_of: [:always, :never, :if_available]
    end

    # Verify the relay's certificate (chain + hostname) on both the implicit-SSL
    # and STARTTLS-upgrade paths by default. An operator on an internal relay
    # with a self-signed or absent cert opts THAT connection out with
    # :verify_none — a stored, visible, per-connection choice, never a global
    # switch.
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
  end

  validations do
    validate AshIntegration.Transport.Validations.CacertPem
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
