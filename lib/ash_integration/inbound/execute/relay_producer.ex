defmodule AshIntegration.Inbound.Execute.RelayProducer do
  @moduledoc false
  # Custom GenStage producer for the command relay. Claims claimable `:pending`
  # `CommandExecution` rows (`Claimer.claim/1` — `FOR UPDATE SKIP LOCKED` + soft
  # lease, oldest first) up to outstanding demand and emits them as Broadway
  # messages. Demand it can't immediately fill is held until the next `:poll`.
  #
  # Discovery is poll-only (no in-process nudge): idle response-command latency ≈
  # the poll interval, uniformly for same-node and cross-node rows. The
  # `SKIP LOCKED` parallel claim is safe because the `claimed_at` fence — not claim
  # order — owns execution correctness.
  use GenStage

  require Logger

  alias AshIntegration.Inbound.Execute.Acknowledger
  alias AshIntegration.Inbound.Execute.Claimer

  @impl true
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
  def handle_info(:poll, state) do
    schedule_poll(state.poll_interval)
    reap_exhausted()
    produce(state)
  end

  def handle_info(_msg, state), do: {:noreply, [], state}

  # On each poll, dead-letter any lease-expired `:pending` row stranded at the
  # attempt ceiling by a crash after its final claim (Claimer.reap_exhausted/0).
  # Normally a no-op (the `WHERE` matches nothing); a transient DB error must not
  # crash the producer, so swallow and let the next poll retry.
  defp reap_exhausted do
    Claimer.reap_exhausted()
  rescue
    e -> Logger.error("Inbound command producer: reap failed: #{Exception.message(e)}")
  end

  # A transient DB error during a claim must never crash the producer (which would
  # tear down the whole pipeline) — log, hold the demand, and let the next
  # demand/poll retry.
  defp produce(state) do
    {messages, remaining} = claim_messages(state.demand, state.claim_limit, [])
    {:noreply, messages, %{state | demand: remaining}}
  rescue
    e ->
      Logger.error("Inbound command producer: claim failed: #{Exception.message(e)}")
      {:noreply, [], state}
  end

  defp claim_messages(0, _limit, acc), do: {Enum.reverse(acc), 0}

  defp claim_messages(demand, limit, acc) do
    case Claimer.claim(min(demand, limit)) do
      [] ->
        {Enum.reverse(acc), demand}

      rows ->
        messages = Enum.map(rows, &to_message/1)
        claim_messages(demand - length(rows), limit, Enum.reverse(messages, acc))
    end
  end

  defp to_message(row) do
    %Broadway.Message{data: row, acknowledger: Acknowledger.for_command(row.id)}
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
end
