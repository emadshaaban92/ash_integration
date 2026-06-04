defmodule AshIntegration.Outbound.Dispatch.Acknowledger do
  @moduledoc false
  # Broadway acknowledger for the dispatch relay.
  #
  # The stamp happens inside the `:dispatch` transaction (handle_batch), atomic with
  # materialization — so a successful message is already dispatched by the time we
  # ack. The ack's remaining jobs are: record a `dispatch_error` for any failed
  # message (it stays undispatched; the lease re-emits, and the `dispatch_attempts`
  # ceiling eventually leaves it stuck — never auto-resolved, #60), and notify the
  # scheduler so lanes waiting on these events get re-evaluated.
  @behaviour Broadway.Acknowledger

  alias AshIntegration.Outbound.Dispatch.Dispatcher
  alias AshIntegration.Outbound.Delivery.Scheduler

  @ack_ref :ash_integration_dispatch

  @doc "The `{module, ack_ref, ack_data}` acknowledger tuple for an event message."
  def for_event(event_id), do: {__MODULE__, @ack_ref, %{event_id: event_id}}

  @impl true
  def ack(@ack_ref, successful, failed) do
    failed
    |> Enum.map(&{event_id(&1), failure_reason(&1)})
    |> Dispatcher.record_dispatch_errors()

    if successful != [] or failed != [], do: Scheduler.notify()

    :ok
  end

  defp event_id(%Broadway.Message{acknowledger: {_mod, _ref, %{event_id: id}}}), do: id

  defp failure_reason(%Broadway.Message{status: {:failed, reason}}) when is_binary(reason),
    do: reason

  defp failure_reason(%Broadway.Message{status: {:failed, reason}}), do: inspect(reason)

  defp failure_reason(%Broadway.Message{status: {kind, reason, _stack}}),
    do: "#{kind}: #{inspect(reason)}"

  defp failure_reason(_), do: "unknown dispatch failure"
end
