defmodule AshIntegration.EventSchedulerTest do
  use ExUnit.Case, async: true

  alias AshIntegration.EventScheduler

  describe "init/1" do
    test "seeds last_run_at so the very first tick is due" do
      # Regression for the `last_run_at: 0` bug: BEAM monotonic time is large
      # and negative at startup, so a seed of 0 made `now - last_run_at`
      # hugely negative and the run guard never passed — the pipeline stalled
      # in :pending forever. The fix seeds from monotonic time instead.
      assert {:ok, %{last_run_at: last_run_at, deferred: false}} = EventScheduler.init([])

      now = System.monotonic_time(:millisecond)
      assert EventScheduler.run_due?(last_run_at, now)
    end
  end

  describe "run_due?/2" do
    test "the old `last_run_at: 0` seed is never due at startup" do
      # At BEAM startup monotonic time is large and negative; with the old
      # seed of 0 the guard `now - 0 >= interval` is false, which is exactly
      # what stalled the scheduler.
      startup_now = -1_000_000_000
      refute EventScheduler.run_due?(0, startup_now)
    end

    test "not due until the minimum interval has elapsed" do
      now = System.monotonic_time(:millisecond)

      # Just ran -> not due; still rate-limited just under the interval.
      refute EventScheduler.run_due?(now, now)
      refute EventScheduler.run_due?(now, now + 999)

      # At/after the interval -> due again.
      assert EventScheduler.run_due?(now, now + 1_000)
      assert EventScheduler.run_due?(now, now + 5_000)
    end

    test "works correctly across negative monotonic values" do
      # Difference-based, so negative absolute times must not matter.
      refute EventScheduler.run_due?(-5_000, -4_500)
      assert EventScheduler.run_due?(-5_000, -4_000)
    end
  end
end
