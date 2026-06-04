defmodule AshIntegration.Outbound.Delivery.Route.RouteConfig do
  @moduledoc """
  Per-subscription delivery route — a transport-tagged union mirroring the
  connection's `AshIntegration.Transport.TransportConfig`. Its variant must match the
  connection's transport type (enforced by
  `AshIntegration.Outbound.Delivery.Validations.SubscriptionRoute`). New transports (gRPC,
  MQTT, …) add a variant here rather than new nullable columns.
  """
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        http: [
          type: AshIntegration.Outbound.Delivery.Route.HttpRoute,
          tag: :type,
          tag_value: :http
        ],
        kafka: [
          type: AshIntegration.Outbound.Delivery.Route.KafkaRoute,
          tag: :type,
          tag_value: :kafka
        ]
      ],
      storage: :map_with_tag
    ]
end
