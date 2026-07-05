defmodule AshIntegration.Transport.KafkaSecurity.Tls do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
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

    # Optional path to a private-CA bundle. When set it REPLACES the OS trust
    # store, so verification pins to exactly the CA that signed the broker cert.
    attribute :cacertfile, :string do
      allow_nil? true
      public? true
    end

    # Optional server-name override for the TLS handshake — some internal brokers
    # front a certificate whose CN differs from the broker address.
    attribute :sni, :string do
      allow_nil? true
      public? true
    end
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
