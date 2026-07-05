defmodule AshIntegration.Outbound.Capture.Event do
  @moduledoc """
  Persistence extension for the immutable **Event** — the fact.

  Computed **once**, at change time, inside the source transaction, under the
  producer's own authority (`AshIntegration.Outbound.Capture.PublishEvent` →
  `Producer.produce/3`). It has a stable identity (its id is the wire `event-id`,
  shared by every subscription that receives it), a point-in-time `data` payload,
  and host-owned provenance. **This table _is_ the transactional outbox** (a relay
  — the dispatch job — fans it out), which is why nothing else is named "Outbox".

  It holds **no delivery state**: fan-out, projection, transform, and the delivery
  state machine live on `AshIntegration.Outbound.Delivery.EventDelivery`. One Event has many
  EventDeliveries.

  Host applications attach this extension to their own resource and wire it via
  `config :ash_integration, event_resource: MyApp.Outbound.Event`. The host may add
  their own attributes (and a change to populate them) for whatever `project` needs.
  """

  use Spark.Dsl.Extension,
    transformers: [
      AshIntegration.Outbound.Capture.Event.Transformer,
      AshIntegration.Outbound.Capture.Event.PolicyTransformer
    ]
end
