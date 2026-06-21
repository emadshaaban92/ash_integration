defmodule AshIntegration.Inbound.Execute.Acknowledger do
  @moduledoc false
  # Broadway acknowledger for the command relay. Execution + finalization already
  # committed (or rolled back) by the time a message is acked — `Inbound.Execute`
  # owns the outcome write — so the ack is a no-op beyond satisfying Broadway. A
  # transiently-failing row was left `:pending` with a backoff cursor and is
  # re-claimed on a later poll; nothing for the ack to do.
  @behaviour Broadway.Acknowledger

  @ack_ref :ash_integration_command

  @doc "The `{module, ack_ref, ack_data}` acknowledger tuple for a command message."
  def for_command(id), do: {__MODULE__, @ack_ref, %{id: id}}

  @impl true
  def ack(@ack_ref, _successful, _failed), do: :ok
end
