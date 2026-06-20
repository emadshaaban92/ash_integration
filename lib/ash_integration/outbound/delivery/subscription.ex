defmodule AshIntegration.Outbound.Delivery.Subscription do
  @moduledoc """
  Persistence extension for an outbound **Subscription**: one
  `(event_type, version)` under a connection, with a single-schema transform. It
  is the per-route half of an integration; the transport/auth half is the
  `AshIntegration.Connection`.

  Host applications attach this extension to their own resource and wire it via
  `config :ash_integration, subscription_resource: MyApp.Outbound.Subscription`.
  Health fields (`active`/`suspended`) — `suspended` is derived from *response*
  rejections by the periodic recompute (`AshIntegration.Outbound.Delivery.Health`).
  """

  use Spark.Dsl.Extension,
    transformers: [AshIntegration.Outbound.Delivery.Subscription.Transformer]
end
