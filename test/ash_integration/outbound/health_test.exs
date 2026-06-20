defmodule AshIntegration.Outbound.Delivery.HealthTest do
  @moduledoc """
  Pure config coverage for the derived-health stage — its `:health` opts schema,
  defaults, and the `window_attempts/0` reader. The recompute/park/probe behaviour
  is exercised against real resources in `Example.Outbound.HealthTest`.
  """
  # async: false — window_attempts/0 reads the global :ash_integration env.
  use ExUnit.Case, async: false

  alias AshIntegration.Outbound.Delivery.Health

  describe "opts_schema/0 defaults" do
    test "match the design doc (N=5, 30s probe, M=3)" do
      defaults = NimbleOptions.validate!([], Health.opts_schema())

      assert defaults[:window_attempts] == 5
      assert defaults[:probe_interval_ms] == 30_000
      assert defaults[:probe_batch] == 3
    end

    test "recompute interval derives from the lease (must exceed the worst-case probe)" do
      defaults = NimbleOptions.validate!([], Health.opts_schema())
      lease_ms = AshIntegration.Outbound.Delivery.Supervisor.lease_seconds() * 1000

      # lease + 30s, and strictly greater than the lease (§13).
      assert defaults[:recompute_interval_ms] == lease_ms + 30_000
      assert defaults[:recompute_interval_ms] > lease_ms
    end
  end

  describe "validate!/1" do
    test "rejects unknown keys and non-positive knobs" do
      assert_raise NimbleOptions.ValidationError, fn -> Health.validate!(nonsense: 1) end
      assert_raise NimbleOptions.ValidationError, fn -> Health.validate!(window_attempts: 0) end
    end
  end

  describe "window_attempts/0" do
    setup do
      original = Application.fetch_env(:ash_integration, :health)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:ash_integration, :health, value)
          :error -> Application.delete_env(:ash_integration, :health)
        end
      end)
    end

    test "defaults to 5" do
      Application.delete_env(:ash_integration, :health)
      assert Health.window_attempts() == 5
    end

    test "reads the configured override" do
      Application.put_env(:ash_integration, :health, window_attempts: 2)
      assert Health.window_attempts() == 2
    end
  end
end
