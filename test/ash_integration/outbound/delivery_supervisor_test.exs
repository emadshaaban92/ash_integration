defmodule AshIntegration.Outbound.Delivery.SupervisorTest do
  @moduledoc """
  Pure config coverage for the delivery stage supervisor — its `:delivery` opts
  schema defaults and the derived-vs-overridable `lease_seconds/0`. The relay
  behaviour itself is exercised against real resources elsewhere.
  """
  # async: false — lease_seconds/0 and concurrency/0 read the global :ash_integration env.
  use ExUnit.Case, async: false

  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage

  # The globally-capped transport timeout the derived lease is built from (default).
  @http_timeout_ms 60_000
  # Fixed headroom added to the (buffer-scaled) timeout — mirrors @lease_margin_ms.
  @lease_margin_ms 30_000

  describe "opts_schema/0 defaults" do
    test "max_demand defaults to 4 (below Broadway's default of 10)" do
      defaults = NimbleOptions.validate!([], Stage.opts_schema())
      assert defaults[:max_demand] == 4
    end

    test "lease_seconds defaults to nil (meaning: derive)" do
      defaults = NimbleOptions.validate!([], Stage.opts_schema())
      assert defaults[:lease_seconds] == nil
    end
  end

  describe "validate!/1" do
    test "rejects unknown keys and non-positive knobs" do
      assert_raise NimbleOptions.ValidationError, fn -> Stage.validate!(nonsense: 1) end
      assert_raise NimbleOptions.ValidationError, fn -> Stage.validate!(max_demand: 0) end
      assert_raise NimbleOptions.ValidationError, fn -> Stage.validate!(lease_seconds: 0) end
    end

    test "accepts nil lease_seconds (the derive sentinel)" do
      assert %{lease_seconds: nil} = Stage.validate!(lease_seconds: nil) |> Map.new()
    end
  end

  describe "lease_seconds/0" do
    setup do
      original = Application.fetch_env(:ash_integration, :delivery)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:ash_integration, :delivery, value)
          :error -> Application.delete_env(:ash_integration, :delivery)
        end
      end)
    end

    test "derives worst-case-safe from max_demand × http_max_timeout + margin by default" do
      Application.delete_env(:ash_integration, :delivery)

      # default max_demand 4 → 4 × 60s + 30s = 270s.
      expected = div(4 * @http_timeout_ms + @lease_margin_ms, 1000)
      assert Stage.lease_seconds() == expected
      assert Stage.lease_seconds() == 270
    end

    test "the derived lease scales with max_demand" do
      Application.put_env(:ash_integration, :delivery, max_demand: 1)
      assert Stage.lease_seconds() == div(1 * @http_timeout_ms + @lease_margin_ms, 1000)

      Application.put_env(:ash_integration, :delivery, max_demand: 8)
      assert Stage.lease_seconds() == div(8 * @http_timeout_ms + @lease_margin_ms, 1000)
    end

    test "an explicit lease_seconds overrides the derivation" do
      Application.put_env(:ash_integration, :delivery, max_demand: 8, lease_seconds: 45)
      # Ignores the buffer-derived value; honours the host's shorter lease.
      assert Stage.lease_seconds() == 45
    end
  end
end
