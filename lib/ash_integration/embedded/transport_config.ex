defmodule AshIntegration.TransportConfig do
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        http: [
          type: AshIntegration.HttpConfig,
          tag: :type,
          tag_value: :http
        ]
      ],
      storage: :map_with_tag
    ]
end
