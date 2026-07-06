defmodule AshIntegration.Inbound.Transport do
  @moduledoc """
  The single source of truth for inbound command **transports**.

  A transport is the channel a command arrived on. Three are designed:

    * `:kafka` — a Broadway consumer (offset replay is the redelivery source);
    * `:http` — a Phoenix endpoint (the caller retries);
    * `:response` — a command derived from a successful outbound HTTP delivery's
      live response (a one-shot artifact — nothing upstream re-presents it).

  The `CommandExecution.transport` attribute's `one_of` constraint derives from
  `transports/0` (mirroring `Transform.Runtime.runtimes/0`), so adding a transport
  is a code change — a new constraint member — **never a schema migration**: the
  column is text and the constraint is checked at cast time, not by a DB `CHECK`.
  """

  @transports [:kafka, :http, :response]

  @doc "Every inbound transport the library knows about."
  @spec transports() :: [atom()]
  def transports, do: @transports

  @doc "Whether `transport` is a known inbound transport."
  @spec valid?(atom()) :: boolean()
  def valid?(transport), do: transport in @transports
end
