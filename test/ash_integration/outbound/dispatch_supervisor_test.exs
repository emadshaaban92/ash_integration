defmodule AshIntegration.Outbound.Dispatch.SupervisorTest do
  @moduledoc """
  Pure config coverage for the dispatch stage supervisor — its `:dispatch` opts
  schema defaults and the buffer↔lease relationship (`max_demand` sized to fit the
  fixed `lease_seconds`). The relay behaviour itself is exercised against real
  resources in the example app's `dispatch_relay_test`.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Dispatch.Supervisor, as: Stage

  describe "opts_schema/0 defaults" do
    test "max_demand defaults to 2 (a shallow buffer, below Broadway's default of 10)" do
      defaults = NimbleOptions.validate!([], Stage.opts_schema())
      assert defaults[:max_demand] == 2
    end
  end

  describe "validate!/1" do
    test "rejects unknown keys and a non-positive max_demand" do
      assert_raise NimbleOptions.ValidationError, fn -> Stage.validate!(nonsense: 1) end
      assert_raise NimbleOptions.ValidationError, fn -> Stage.validate!(max_demand: 0) end
    end

    test "accepts an explicit max_demand override" do
      assert %{max_demand: 3} = Stage.validate!(max_demand: 3) |> Map.new()
    end
  end

  describe "buffer vs lease" do
    test "the default standing buffer per processor comfortably fits the fixed lease" do
      # Unlike delivery, dispatch's lease is a constant and the buffer is sized to FIT
      # it: `max_demand` prefetched events each stand leased while waiting behind slow
      # `project/3` + Lua transforms, so keep the buffer shallow (well below Broadway's
      # default of 10) against the fixed lease window.
      max_demand = NimbleOptions.validate!([], Stage.opts_schema())[:max_demand]

      assert max_demand < 10
      assert Stage.lease_seconds() == 60
    end
  end
end
