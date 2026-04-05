defmodule AshIntegration.TransportConfig do
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        http: [
          type: AshIntegration.HttpConfig,
          tag: :type,
          tag_value: :http
        ],
        kafka: [
          type: AshIntegration.KafkaConfig,
          tag: :type,
          tag_value: :kafka
        ]
      ],
      storage: :map_with_tag
    ]
end
