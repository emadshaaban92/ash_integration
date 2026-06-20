defmodule AshIntegration.Outbound.ParkedHealthTest do
  @moduledoc """
  Unit coverage for the parked-health derivation and its config knobs — the pure
  bits, no DB. Park is a recoverable build failure: it must surface as a non-healthy
  derived status WITHOUT touching the transport/response suspension counters. The
  aggregate-backed + dashboard + auto-suspend behaviour is exercised against real
  resources in `Example.Outbound.ParkedHealthTest`.
  """
  # async: false — the parked-suspension tests mutate the global :ash_integration env.
  use ExUnit.Case, async: false

  alias AshIntegration.Outbound.Delivery.ParkedHealth

  describe "status/1 (default threshold 10)" do
    test "no parked deliveries reads :healthy" do
      assert ParkedHealth.status(%{parked_count: 0}) == :healthy
      refute ParkedHealth.unhealthy?(%{parked_count: 0})
    end

    test "a parked backlog below the threshold reads :degraded" do
      assert ParkedHealth.status(%{parked_count: 1}) == :degraded
      assert ParkedHealth.status(%{parked_count: 9}) == :degraded
      assert ParkedHealth.unhealthy?(%{parked_count: 1})
    end

    test "a parked backlog at/above the threshold reads :parked (chronically parked)" do
      assert ParkedHealth.status(%{parked_count: 10}) == :parked
      assert ParkedHealth.status(%{parked_count: 999}) == :parked
      assert ParkedHealth.unhealthy?(%{parked_count: 10})
    end

    test "an unloaded aggregate raises rather than silently reading healthy" do
      # Built via `Map.new/1` (typed as generic `map()`) so Elixir 1.20's type
      # checker doesn't prove this call always raises — it intentionally does, but a
      # static `%{parked_count: %Ash.NotLoaded{}}` literal trips --warnings-as-errors.
      unloaded = Map.new(parked_count: %Ash.NotLoaded{})

      assert_raise ArgumentError, ~r/not loaded/, fn ->
        ParkedHealth.status(unloaded)
      end
    end
  end

  describe "parked_health_threshold/0" do
    setup do: reset_env(:parked_health_threshold)

    test "defaults to 10" do
      Application.delete_env(:ash_integration, :parked_health_threshold)
      assert AshIntegration.parked_health_threshold() == 10
    end

    test "is honoured by status/1" do
      Application.put_env(:ash_integration, :parked_health_threshold, 3)
      assert ParkedHealth.status(%{parked_count: 2}) == :degraded
      assert ParkedHealth.status(%{parked_count: 3}) == :parked
    end
  end

  describe "parked_suspension config (opt-in, default OFF)" do
    setup do: reset_env(:parked_suspension)

    test "is disabled by default" do
      Application.delete_env(:ash_integration, :parked_suspension)
      refute AshIntegration.parked_suspension_enabled?()
      assert AshIntegration.parked_suspension_threshold() == 50
    end

    test "reads enabled? and count_threshold from config" do
      Application.put_env(:ash_integration, :parked_suspension,
        enabled?: true,
        count_threshold: 5
      )

      assert AshIntegration.parked_suspension_enabled?()
      assert AshIntegration.parked_suspension_threshold() == 5
    end
  end

  defp reset_env(key) do
    original = Application.fetch_env(:ash_integration, key)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ash_integration, key, value)
        :error -> Application.delete_env(:ash_integration, key)
      end
    end)

    :ok
  end
end
