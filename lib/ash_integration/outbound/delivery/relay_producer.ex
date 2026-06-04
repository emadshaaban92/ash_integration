defmodule AshIntegration.Outbound.Delivery.RelayProducer do
  @moduledoc false
  # Custom GenStage producer for the delivery relay — the delivery-side mirror of
  # `AshIntegration.Outbound.Dispatch.RelayProducer`.
  #
  # Claims DUE `:scheduled` `EventDelivery` rows (`Dispatcher.claim/1` — `FOR UPDATE
  # SKIP LOCKED` + soft lease, oldest first, honoring `next_attempt_at` backoff and
  # the poison ceiling) up to outstanding demand and emits them as Broadway
  # messages. Demand it can't immediately fill is held until the next `:poll`
  # re-checks. Discovery is poll-only: end-to-end idle latency ≈ the poll interval.
  #
  # `SKIP LOCKED` parallel claim is safe because the scheduler owns ordering (only
  # one `:scheduled` row per `(connection, event_key)` exists — the partial unique
  # index), so any claimed batch is a set of distinct lane heads.
  use GenStage

  require Logger

  alias AshIntegration.Outbound.Delivery.Acknowledger
  alias AshIntegration.Outbound.Delivery.Dispatcher

  @impl true
  # Tuning is passed down from the stage supervisor via the relay's producer spec
  # (`{RelayProducer, poll_interval_ms: …, claim_limit: …}`) — the producer never
  # reads `Application.get_env` itself.
  def init(opts) do
    poll_interval = Keyword.fetch!(opts, :poll_interval_ms)
    schedule_poll(poll_interval)

    {:producer,
     %{
       demand: 0,
       poll_interval: poll_interval,
       claim_limit: Keyword.fetch!(opts, :claim_limit)
     }}
  end

  @impl true
  def handle_demand(incoming, state) when incoming > 0 do
    produce(%{state | demand: state.demand + incoming})
  end

  @impl true
  # The sole discovery trigger: pick up rows newly promoted to `:scheduled` (this
  # node or any other) or whose backoff just elapsed. Reschedules itself. It does
  # NOT reap poison rows — a terminally-stuck delivery is left `:scheduled` with its
  # lane blocked by design (#60) until a human/host resolves it.
  def handle_info(:poll, state) do
    schedule_poll(state.poll_interval)
    produce(state)
  end

  def handle_info(_msg, state), do: {:noreply, [], state}

  # Drain up to `demand` rows, claiming in chunks of `claim_limit`. A transient DB
  # error during a claim must never crash the producer (which would tear down the
  # whole pipeline) — log, hold the demand, and let the next demand/poll retry.
  defp produce(state) do
    {messages, remaining} = claim_messages(state.demand, state.claim_limit, [])
    {:noreply, messages, %{state | demand: remaining}}
  rescue
    e ->
      Logger.error("Outbound delivery producer: claim failed: #{Exception.message(e)}")
      {:noreply, [], state}
  end

  defp claim_messages(0, _limit, acc), do: {Enum.reverse(acc), 0}

  defp claim_messages(demand, limit, acc) do
    case Dispatcher.claim(min(demand, limit)) do
      [] ->
        {Enum.reverse(acc), demand}

      deliveries ->
        messages = Enum.map(deliveries, &to_message/1)
        claim_messages(demand - length(deliveries), limit, Enum.reverse(messages, acc))
    end
  end

  defp to_message(delivery) do
    %Broadway.Message{data: delivery, acknowledger: Acknowledger.for_delivery(delivery.id)}
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
end
