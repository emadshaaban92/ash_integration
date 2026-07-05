defmodule AshIntegration.Outbound.Delivery.EventDelivery do
  @moduledoc """
  Persistence extension for an outbound **EventDelivery**: one per
  `(immutable Event, subscription)` that the `project` hook decided to deliver,
  carrying the materialized (projected + transformed) wire descriptor and the
  delivery state machine.

  It holds `state`, `attempts`, `delivery`, `delivery_metadata`, and points
  upstream at the immutable `Event` via `event_id`. `event_type`/`version`/
  `event_key` are denormalized from the parent Event for display without a join.

  Lane ordering is on `event_id` — the parent Event's UUIDv7, which is
  occurrence-ordered (capture is synchronous, so the Event's id reflects when the
  change happened). The delivery's own `id` is generated at dispatch time, so it
  is NOT occurrence-order and must not be used for ordering.

  Ordering serializes at most one in-flight (`scheduled`) delivery per
  `(connection_id, event_key)` via a partial unique index; coalescing collapses
  pending deliveries per `(subscription_id, event_key)`.

  Host applications attach this extension to their own resource and wire it via
  `config :ash_integration, event_delivery_resource: MyApp.Outbound.EventDelivery`.
  """

  use Spark.Dsl.Extension,
    transformers: [
      AshIntegration.Outbound.Delivery.EventDelivery.Transformer,
      AshIntegration.Outbound.Delivery.EventDelivery.PolicyTransformer
    ]
end
