defmodule AshIntegration.LuaSandboxLimitsTest do
  # Not async: tightens the global `:lua_sandbox` limits to keep the bomb tests
  # fast and light.
  use ExUnit.Case, async: false

  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat
  alias AshIntegration.Test.LuaBackend

  setup do
    original = Application.get_env(:ash_integration, :lua_sandbox)

    # Small budgets so the allocation/loop bombs die quickly and cheaply.
    Application.put_env(:ash_integration, :lua_sandbox,
      timeout_ms: 1_000,
      max_steps: 1_000_000,
      max_heap_words: 200_000
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_integration, :lua_sandbox)
        value -> Application.put_env(:ash_integration, :lua_sandbox, value)
      end
    end)

    :ok
  end

  # The assertions below are written in the runtime-neutral `Limits` vocabulary
  # (`max_steps`, "step budget") and on the OBSERVABLE outcome — the delivery
  # parks with a resource-limit message — rather than on either backend's native
  # error tuple. Where the backends genuinely differ, there is a per-backend test
  # (`lua_pcall_budget_test.exs`, and `backend/0` branches here), never a weakened
  # assertion that both happen to satisfy.
  defp resource_limit_message?(message) do
    message =~ "step budget" or message =~ "timed out" or message =~ "killed"
  end

  test "an allocation-bomb transform is killed without taking down the caller" do
    bomb = ~S"""
    function transform(event, defaults)
      local t = {}
      local i = 1
      while true do
        t[i] = string.rep("x", 1024)
        i = i + 1
      end
    end
    """

    assert {:error, message} = Lua.execute(bomb, %{})
    assert is_binary(message)

    # The caller (this test process) is unharmed and the sandbox still works for a
    # well-behaved script afterwards — proving crash isolation + recovery.
    assert {:ok, %{"ok" => true}} =
             Lua.execute(~S|function transform(e, d) return {ok = true} end|, %{})
  end

  test "a tight infinite loop is stopped and the delivery parks" do
    bomb = ~S|function transform(e, d) while true do end end|
    assert {:error, message} = Lua.execute(bomb, %{})
    assert resource_limit_message?(message)
  end

  test "the step budget is what stops a tight loop, and it says so" do
    # The wall-clock backstop is a second away; the step budget is 1M. Whichever
    # unit the backend counts in, the message an operator sees in `last_error`
    # names the step budget.
    assert {:error, message} =
             Lua.execute(~S|function transform(e, d) while true do end end|, %{})

    assert message =~ "script exceeded its step budget"
  end

  test "a host API called in a tight loop is bounded by the same budgets" do
    # Host functions are invoked by whichever process runs the Lua code (luerl's
    # runner on `:luerl`, the transform Task itself on `:lua_vm`), so their work
    # and allocations count against the script's ceilings — an operator can't use
    # `datetime` to buy unbounded work.
    bomb = ~S"""
    function transform(event, defaults)
      local out = {}
      local i = 1
      while true do
        out[i] = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")
        i = i + 1
      end
    end
    """

    assert {:error, message} = Lua.execute(bomb, %{})
    assert resource_limit_message?(message)
  end

  test "a legitimate transform still runs under the tightened budgets" do
    assert {:ok, %{"doubled" => 84}} =
             Lua.execute(
               ~S|function transform(event, d) return {doubled = event.n * 2} end|,
               %{"n" => 42}
             )
  end

  test "a signing callback that runs away parks the whole session" do
    source = ~S|function string_to_sign(ctx) while true do end end|

    assert {:error, message} =
             Lua.sign_session(source, Lua.default_limits(), fn call ->
               call.("string_to_sign", %{"body" => "payload"})
             end)

    assert resource_limit_message?(message)
  end

  describe "config" do
    test ":max_steps sets the step budget" do
      Application.put_env(:ash_integration, :lua_sandbox, max_steps: 12_345)
      assert Lua.default_limits().max_steps == 12_345
    end

    test ":max_reductions is still honoured as the deprecated alias" do
      # It named luerl's own flag, which the `:lua_vm` backend has no equivalent
      # for — but a host that set it must keep its configured ceiling rather than
      # silently reverting to the (much larger) default.
      Application.put_env(:ash_integration, :lua_sandbox, max_reductions: 54_321)
      assert Lua.default_limits().max_steps == 54_321
    end

    test ":max_steps wins when both are set" do
      Application.put_env(:ash_integration, :lua_sandbox,
        max_steps: 111,
        max_reductions: 222
      )

      assert Lua.default_limits().max_steps == 111
    end
  end

  describe "the compiled-against backend" do
    test "is one of the two this runtime supports, and reports its version" do
      assert Compat.backend() in [:luerl, :lua_vm]
      assert Compat.lua_version() =~ ~r/^\d+\.\d+\.\d+/
      assert Compat.lua_version() == to_string(Application.spec(:lua, :vsn))

      # `Compat` decides at COMPILE time; `LuaBackend` re-derives it at run time
      # from the loaded `:lua` application. A shim that compiled against one
      # backend and ran against the other is the failure mode this pins.
      assert Compat.backend() == LuaBackend.backend()
    end

    test "the version gate admits pre-releases" do
      # `Version.match?/2` excludes pre-releases from a requirement that carries
      # none, so `">= 1.0.0"` answers false for `1.0.0-rc.1` — which would compile
      # the luerl branch against the 1.0 VM and park every delivery. `mix.exs`
      # accepts `~> 1.0`, so Hex can resolve such a version without anyone
      # touching the constraint. Both gates must use the `-0` form.
      refute Version.match?("1.0.0-rc.1", ">= 1.0.0")
      assert Version.match?("1.0.0-rc.1", ">= 1.0.0-0")
      assert Version.match?("0.4.0", ">= 1.0.0-0") == false
    end

    @tag timeout: 30_000
    test "the wall-clock ceiling is the configured one, on both backends" do
      # Neither backend has a usable inner timer — `lua 1.0` has none, and
      # `lua 0.4`'s `max_time` is only consulted once its runner has already
      # terminated whenever `max_reductions` is set — so the outer Task waits
      # exactly `timeout_ms` and no grace beyond it. A blocking host call is the
      # one case that reaches the Task's timer with the step budget unable to
      # fire, which is precisely what makes this measurable.
      Application.put_env(:ash_integration, :lua_sandbox,
        timeout_ms: 300,
        max_steps: 100_000_000,
        max_heap_words: 500_000,
        apis: [AshIntegration.Test.BlockingLuaAPI]
      )

      {micros, result} =
        :timer.tc(fn ->
          Lua.execute(~S|function transform(e, d) return {x = blocking.sleep(10000)} end|, %{})
        end)

      assert {:error, message} = result
      assert message =~ "timed out" or message =~ "crashed or was killed"

      # Generous upper bound (scheduling noise, CI), but far below the 1_300ms a
      # one-second grace would produce.
      elapsed = div(micros, 1000)
      assert elapsed < 1_000, "expected ~300ms wall-clock ceiling, waited #{elapsed}ms"
    end
  end
end
