defmodule AshIntegration.Outbound.Declare.Dsl.Version do
  @moduledoc """
  A supported schema version of an event type.

  A version is just a number — the unit a subscription binds to. The payload is
  a single JSONB `data` map, so there is no per-version schema module here.
  """

  defstruct [:number, :__spark_metadata__]
end
