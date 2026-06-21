defmodule AshIntegration.Inbound.Declare.Registration do
  @moduledoc """
  The routing value for one command type: the resolved `(resource, action,
  handler)` triple the core executes a command through.

  It is a **struct, not a tuple** — adding a field later (a `version`, a queue
  tag, a per-type concurrency cap, or the `target` shape for non-resource command
  targets) is additive instead of a positional break everywhere a tuple was
  matched. The `inbound_commands` DSL + `Registry` build a
  `%{canonical_command_type => %Registration{}}` map; the core's routing input is
  exactly that plain map, so tests hand the core a literal and a future host that
  wants no DSL passes its own. The dependency arrow points one way
  (DSL → data → core), never back.
  """

  @enforce_keys [:command_type, :resource, :action, :handler]
  defstruct [:command_type, :resource, :action, :handler]

  @type t :: %__MODULE__{
          command_type: String.t(),
          resource: module(),
          action: atom(),
          handler: module()
        }
end
