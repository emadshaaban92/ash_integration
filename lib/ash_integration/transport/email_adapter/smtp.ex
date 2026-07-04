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
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
