defmodule AshIntegration.Transport.KafkaConfig do
  @vault Application.compile_env!(:ash_integration, :vault)

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

    # Connection-level default topic. A subscription may override it; the topic
    # used for a delivery is `subscription.topic || this default`.
    attribute :topic, :string do
      allow_nil? true
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
                      type: AshIntegration.Transport.KafkaSecurity.None,
                      tag: :type,
                      tag_value: "none"
                    ],
                    tls: [
                      type: AshIntegration.Transport.KafkaSecurity.Tls,
                      tag: :type,
                      tag_value: "tls"
                    ],
                    sasl: [
                      type: AshIntegration.Transport.KafkaSecurity.Sasl,
                      tag: :type,
                      tag_value: "sasl"
                    ],
                    sasl_tls: [
                      type: AshIntegration.Transport.KafkaSecurity.SaslTls,
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
