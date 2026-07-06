defmodule AshIntegration.Inbound.Declare.Dsl.Command do
  @moduledoc """
  A `command` declaration inside `inbound_commands`: this resource's claim to be
  the **single executor** of a named command type.

  - `type` — the command-type token (`"record_partner_ref"`). The DSL accepts a
    string or an atom for authoring comfort; `AshIntegration.Inbound.Declare.Info`
    normalizes it to the canonical (downcased) string.
  - `action` — the Ash action on **this** resource the command applies through.
  - `handler` — the `AshIntegration.Inbound.Declare.Handler` module that maps a
    payload to that action's input.
  """

  defstruct [
    :type,
    :action,
    :handler,
    __identifier__: nil,
    __spark_metadata__: nil
  ]
end
