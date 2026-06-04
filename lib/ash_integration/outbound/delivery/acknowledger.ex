defmodule AshIntegration.Outbound.Delivery.Acknowledger do
  @moduledoc false
  # Broadway acknowledger for the delivery relay.
  #
  # All durable writes (the `:deliver` / `:record_attempt_error` / `:reset_to_pending`
  # actions, with their suspension + backoff + poison bookkeeping) happen INLINE in
  # the relay's `handle_batch`, where the per-row `deliver_batch/2` results and the
  # lease token are in hand. So the ack's only job is to notify the scheduler, so a
  # lane whose slot was just freed (a delivered/cancelled/reset row) gets its next
  # head promoted promptly instead of waiting for the idle sweep.
  @behaviour Broadway.Acknowledger

  alias AshIntegration.Outbound.Delivery.Scheduler

  @ack_ref :ash_integration_delivery

  @doc "The `{module, ack_ref, ack_data}` acknowledger tuple for a delivery message."
  def for_delivery(delivery_id), do: {__MODULE__, @ack_ref, %{delivery_id: delivery_id}}

  @impl true
  def ack(@ack_ref, successful, failed) do
    if successful != [] or failed != [], do: Scheduler.notify()
    :ok
  end
end
