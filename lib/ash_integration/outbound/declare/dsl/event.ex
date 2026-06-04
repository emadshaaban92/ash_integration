defmodule AshIntegration.Outbound.Declare.Dsl.Event do
  @moduledoc """
  An `event` declaration inside `outbound_events`: this resource's
  contribution to a named, versioned event type.

  - `type` — the event-type string (`"product.created"`). The DSL accepts a
    string or an atom for authoring comfort; `AshIntegration.Outbound.Declare.Source.Info`
    normalizes it to the canonical string.
  - `actions` — the internal Ash action names that contribute this event.
  - `producer` — the `AshIntegration.Outbound.Declare.Producer` module for this event type.
  - `versions` — the supported `version` entities (just a version number).
  """

  defstruct [
    :type,
    :actions,
    :producer,
    capture_isolation?: false,
    versions: [],
    __identifier__: nil,
    __spark_metadata__: nil
  ]
end
