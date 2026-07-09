defmodule Example.Outbound.RelayProducerDrainingTest do
  @moduledoc """
  Graceful-shutdown contract for both relay producers (dispatch + delivery).

  Each producer implements `Broadway.Producer` so Broadway invokes
  `prepare_for_draining/1` when a rolling deploy drains the pipeline. Without it,
  the `:poll` timer keeps firing during shutdown and keeps claiming rows that are
  then dropped — each stranded for a full lease (60–90s) before another node
  re-claims it. These tests exercise the callbacks directly (no DB): once draining
  latches, the producer cancels its poll and refuses to emit, so shutdown claims
  nothing.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Dispatch.RelayProducer, as: DispatchProducer
  alias AshIntegration.Outbound.Delivery.RelayProducer, as: DeliveryProducer

  @producers [DispatchProducer, DeliveryProducer]
  # A poll interval far longer than the test so the init timer never fires on its
  # own — every timer transition here is one the code under test made.
  @opts [poll_interval_ms: 60_000, claim_limit: 10]

  for producer <- @producers do
    describe "#{inspect(producer)} draining" do
      setup do
        {:producer, state} = unquote(producer).init(@opts)
        %{producer: unquote(producer), state: state}
      end

      test "init schedules a poll and starts un-drained", %{state: state} do
        assert state.draining == false
        assert is_reference(state.poll_timer)
      end

      test "prepare_for_draining cancels the poll timer and latches draining", %{
        producer: producer,
        state: state
      } do
        assert {:noreply, [], drained} = producer.prepare_for_draining(state)

        assert drained.draining == true
        assert is_nil(drained.poll_timer)
        # The timer was live; cancelling it returns remaining ms (an integer), not
        # `false` (which would mean it had already fired/been cancelled).
        assert Process.cancel_timer(state.poll_timer) == false
      end

      test "a :poll that lands after draining is swallowed — no reschedule, no claim", %{
        producer: producer,
        state: state
      } do
        {:noreply, [], drained} = producer.prepare_for_draining(state)

        assert {:noreply, [], ^drained} = producer.handle_info(:poll, drained)
        # Nothing was rescheduled: no new poll message is queued to this process.
        refute_received :poll
      end

      test "late demand while draining is tallied but nothing is emitted", %{
        producer: producer,
        state: state
      } do
        {:noreply, [], drained} = producer.prepare_for_draining(state)

        assert {:noreply, [], after_demand} = producer.handle_demand(5, drained)
        assert after_demand.demand == 5
        assert after_demand.draining == true
      end
    end
  end
end
