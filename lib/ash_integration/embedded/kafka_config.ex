defmodule AshIntegration.KafkaConfig do
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
    attribute :brokers, {:array, :string} do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :topic, :string do
      allow_nil? false
      public? true
    end

    attribute :headers, :map do
      public? true
      default %{}
    end

    attribute :signing_secret, :string do
      public? true
      sensitive? true
    end

    attribute :security, :union do
      allow_nil? false
      public? true
      default %{type: "none"}

      constraints types: [
                    none: [
                      type: AshIntegration.KafkaSecurity.None,
                      tag: :type,
                      tag_value: "none"
                    ],
                    tls: [
                      type: AshIntegration.KafkaSecurity.Tls,
                      tag: :type,
                      tag_value: "tls"
                    ],
                    sasl: [
                      type: AshIntegration.KafkaSecurity.Sasl,
                      tag: :type,
                      tag_value: "sasl"
                    ],
                    sasl_tls: [
                      type: AshIntegration.KafkaSecurity.SaslTls,
                      tag: :type,
                      tag_value: "sasl_tls"
                    ]
                  ],
                  storage: :map_with_tag
    end

    attribute :acks, :atom do
      allow_nil? false
      public? true
      default :all
      constraints one_of: [:all, :leader, :none]
    end

    attribute :delivery_timeout_ms, :integer do
      allow_nil? false
      public? true
      default 30_000
      constraints min: 1000
    end
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
