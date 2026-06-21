defmodule AshIntegration.Inbound.Declare.Commands do
  @moduledoc """
  Resource-level `inbound_commands` DSL: declares which command types this
  resource executes, the action each applies through, and the handler that maps a
  payload to that action's input.

  Mirrors `outbound_events` in shape and **inverts** it in semantics: an event
  type is the *union* of every declaration naming it (many sources, one fact); a
  command type has **exactly one** executor, so a type declared on two resources
  is ambiguous routing — a boot error (`Registry.verify!/0`), not a richer
  declaration.

      use Ash.Resource,
        extensions: [AshIntegration.Inbound.Declare.Commands]

      inbound_commands do
        command "record_partner_ref" do
          action :record_partner_ref          # must exist on THIS resource
          handler MyApp.Inbound.RecordPartnerRef
        end
      end
  """

  @command %Spark.Dsl.Entity{
    name: :command,
    describe: "Declares a command type this resource is the single executor of.",
    target: AshIntegration.Inbound.Declare.Dsl.Command,
    args: [:type],
    identifier: :type,
    schema: [
      type: [
        type: {:or, [:string, :atom]},
        required: true,
        doc: "Command type, e.g. \"record_partner_ref\" (string or atom; stored as a string)."
      ],
      action: [
        type: :atom,
        required: true,
        doc: "The Ash action on this resource the command applies through."
      ],
      handler: [
        type: :atom,
        required: true,
        doc: "An `AshIntegration.Inbound.Declare.Handler` module for this command type."
      ]
    ]
  }

  @inbound_commands %Spark.Dsl.Section{
    name: :inbound_commands,
    describe: "Declare which command types this resource executes, and how.",
    entities: [@command]
  }

  use Spark.Dsl.Extension,
    sections: [@inbound_commands],
    verifiers: [AshIntegration.Inbound.Declare.Verifier]
end
