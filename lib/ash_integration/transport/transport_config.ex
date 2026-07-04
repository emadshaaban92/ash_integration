defmodule AshIntegration.Transport.TransportConfig do
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        http: [
          type: AshIntegration.Transport.HttpConfig,
          tag: :type,
          tag_value: :http
        ],
        kafka: [
          type: AshIntegration.Transport.KafkaConfig,
          tag: :type,
          tag_value: :kafka
        ],
        email: [
          type: AshIntegration.Transport.EmailConfig,
          tag: :type,
          tag_value: :email
        ]
      ],
      storage: :map_with_tag
    ]
end
