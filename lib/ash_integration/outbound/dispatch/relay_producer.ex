defmodule AshIntegration.Outbound.Dispatch.RelayProducer do
  @moduledoc false
  # Custom GenStage producer for the dispatch relay.
  #
  # No off-the-shelf Postgres Broadway producer exists, so we write one: it claims
  # undispatched `Event`s (`Dispatcher.claim/1` — `FOR UPDATE SKIP LOCKED` + soft
  # lease, oldest first) up to outstanding demand and emits them as Broadway
  # messages. Demand it can't immediately fill is held until the next `:poll`
  # re-checks the outbox. Discovery is poll-only (no capture nudge): end-to-end
  # idle latency ≈ the poll interval, uniformly for same-node and cross-node
  # captures, and under load the demand loop drains continuously regardless.
  #
  # `SKIP LOCKED` parallel claim is safe here ONLY because the scheduler
  # high-water gate owns ordering correctness, not claim order.
  #
  # Implements `Broadway.Producer` (not just `GenStage`) for one reason: the
  # `prepare_for_draining/1` hook. On a rolling deploy Broadway drains the pipeline
  # before shutting it down; without the hook the `:poll` timer keeps firing and
  # keeps claiming rows that are then dropped when the process dies, each stranded
  # for a full lease (60–90s) before another node re-claims it. Cancelling the poll
  # and refusing to emit once draining begins keeps deploys hiccup-free.
  use GenStage
  @behaviour Broadway.Producer

  require Logger

  alias AshIntegration.Outbound.Dispatch.Acknowledger
  alias AshIntegration.Outbound.Dispatch.Dispatcher

  @impl GenStage
  # Tuning is passed down from the stage supervisor via the relay's producer spec
  # (`{RelayProducer, poll_interval_ms: …, claim_limit: …}`) — the producer never
  # reads `Application.get_env` itself.
  def init(opts) do
    poll_interval = Keyword.fetch!(opts, :poll_interval_ms)
    timer = schedule_poll(poll_interval)

    {:producer,
     %{
       demand: 0,
       poll_interval: poll_interval,
       claim_limit: Keyword.fetch!(opts, :claim_limit),
       poll_timer: timer,
       draining: false
     }}
  end

  @impl GenStage
  # While draining, absorb any late demand into the tally but emit nothing — the
  # pipeline is shutting down and a claimed row would only be dropped.
  def handle_demand(incoming, %{draining: true} = state) when incoming > 0 do
    {:noreply, [], %{state | demand: state.demand + incoming}}
  end

  def handle_demand(incoming, state) when incoming > 0 do
    produce(%{state | demand: state.demand + incoming})
  end

  @impl GenStage
  # The sole discovery trigger: pick up newly-committed events (from this node or
  # any other). Reschedules itself. (It does NOT reap poison rows: a
  # terminally-stuck event is left undispatched and keeps its lane blocked by
  # design until a human/host resolves it; we never auto-resolve.)
  #
  # A `:poll` already sitting in the mailbox when draining begins lands here after
  # `prepare_for_draining/1` flipped the flag — swallow it (don't reschedule, don't
  # claim) so shutdown claims nothing.
  def handle_info(:poll, %{draining: true} = state), do: {:noreply, [], state}

  def handle_info(:poll, state) do
    timer = schedule_poll(state.poll_interval)
    produce(%{state | poll_timer: timer})
  end

  def handle_info(_msg, state), do: {:noreply, [], state}

  @impl Broadway.Producer
  # Invoked once when Broadway starts draining the pipeline (rolling deploy / stop).
  # Cancel the pending poll and latch `draining` so no further rows are claimed:
  # a row claimed now would be leased and then dropped on shutdown, stuck for a full
  # lease (60–90s) before another node re-claims it.
  def prepare_for_draining(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    {:noreply, [], %{state | draining: true, poll_timer: nil}}
  end

  # Drain up to `demand` events, claiming in chunks of `claim_limit`. Stops when
  # demand is satisfied or the outbox is empty; any unfilled demand is carried.
  defp produce(state) do
    {messages, remaining} = claim_messages(state.demand, state.claim_limit, [])
    {:noreply, messages, %{state | demand: remaining}}
  end

  defp claim_messages(0, _limit, acc), do: {Enum.reverse(acc), 0}

  defp claim_messages(demand, limit, acc) do
    case Dispatcher.claim(min(demand, limit)) do
      [] ->
        # Outbox drained — hold the leftover demand for the next poll.
        {Enum.reverse(acc), demand}

      events ->
        messages = Enum.map(events, &to_message/1)
        claim_messages(demand - length(events), limit, Enum.reverse(messages, acc))
    end
  rescue
    # A transient DB error during a claim must never crash the producer (which would
    # tear down the whole pipeline). `Dispatcher.claim/1` already rolls back + returns
    # [] on a blip, so this pass should never raise — but if it somehow does, emit every
    # message already built this pass (dropping them would strand their leased rows for a
    # full lease window) and hold the unfilled demand for the next poll.
    e ->
      Logger.error("Outbound dispatch producer: claim failed: #{Exception.message(e)}")
      {Enum.reverse(acc), demand}
  end

  defp to_message(event) do
    %Broadway.Message{data: event, acknowledger: Acknowledger.for_event(event.id)}
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
end
