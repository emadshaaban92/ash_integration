defmodule AshIntegration.Outbound.Declare.Source do
  @moduledoc """
  Source-trigger DSL extension: declares which of a resource's actions
  contribute to which **event types**, and the producer that captures each event.

  Host applications add this extension to their domain resources (the things
  that change — `Product`, `InventoryItem`, …):

      use Ash.Resource,
        extensions: [AshIntegration.Outbound.Declare.Source]

      outbound_events do
        # `source_resource` is optional — it defaults to the resource's short_name.
        # Declare it only to pin provenance across renames or match an external name.
        source_resource "product"

        event "product.created" do
          actions [:create]
          producer Example.Outbound.ProductCreated
          version 1
        end

        event "stock.changed" do
          actions [:update, :destroy]
          producer Example.Outbound.StockChanged
          version 1
        end
      end

  An event type is the **union** of every resource-level declaration that names
  it (same string = same logical event). The event key is *not* a DSL field —
  it is produced by the producer's `event_key/2` (see
  `AshIntegration.Outbound.Declare.Producer`).
  """

  @version %Spark.Dsl.Entity{
    name: :version,
    describe: "A supported schema version for this event (the unit a subscription binds to).",
    target: AshIntegration.Outbound.Declare.Dsl.Version,
    args: [:number],
    schema: [
      number: [
        type: :pos_integer,
        required: true,
        doc: "The schema version number."
      ]
    ]
  }

  @event %Spark.Dsl.Entity{
    name: :event,
    describe: "Declares an event type this resource contributes to.",
    target: AshIntegration.Outbound.Declare.Dsl.Event,
    args: [:type],
    identifier: :type,
    entities: [versions: [@version]],
    schema: [
      type: [
        type: {:or, [:string, :atom]},
        required: true,
        doc: "Event type, e.g. \"product.created\" (string or atom; stored as a string)."
      ],
      actions: [
        type: {:list, :atom},
        required: true,
        doc: "The Ash action names whose execution contributes this event type."
      ],
      producer: [
        type: :atom,
        required: true,
        doc: "An `AshIntegration.Outbound.Declare.Producer` module for this event type."
      ],
      capture_isolation?: [
        type: :boolean,
        required: false,
        default: false,
        doc:
          "When true, a capture failure for THIS event (a raising `produce`/`event_key`) is " <>
            "caught, logged, and the event is DROPPED instead of rolling back the host's " <>
            "business action. Default false: capture failures fail the action (outbox integrity)."
      ]
    ]
  }

  @outbound_events %Spark.Dsl.Section{
    name: :outbound_events,
    describe: "Declare which actions of this resource contribute to which event types.",
    schema: [
      source_resource: [
        type: :string,
        required: false,
        doc:
          "External identifier for this resource, stored as the Event's `source_resource` " <>
            "provenance. Optional — defaults to the resource's short_name; declare it to pin " <>
            "provenance across module renames or to match an external system's naming."
      ]
    ],
    entities: [@event]
  }

  use Spark.Dsl.Extension,
    sections: [@outbound_events],
    transformers: [AshIntegration.Outbound.Declare.Source.Transformer],
    verifiers: [AshIntegration.Outbound.Declare.Source.Verifier]
end
