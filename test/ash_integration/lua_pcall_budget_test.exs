defmodule AshIntegration.LuaPcallBudgetTest do
  # Not async: tightens the global `:lua_sandbox` limits so the runaway loops die
  # quickly.
  use ExUnit.Case, async: false

  @moduledoc """
  The one place the `lua 0.4` / `lua 1.0` abstraction is known to leak, pinned on
  both backends.

  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat` can hide *where*
  the CPU ceiling is configured, but not what happens when a script hits it:

    * `:luerl` enforces it by **killing** the process the Lua code runs in.
      `pcall` cannot catch a process kill, so a runaway always parks the delivery.
    * `:lua_vm` enforces it by **raising a Lua error**, which `pcall` catches. The
      budget is per top-level evaluation and is never refilled — so a script
      cannot buy more CPU by catching it — but it CAN burn the whole budget, catch
      the error, and go on to return a normal result.

  Transform sources are operator-authored but untrusted at runtime, so this is a
  security property, not a curiosity. These are deliberately per-backend
  assertions: weakening them to something both backends satisfy would hide exactly
  the difference they exist to record.
  """

  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua
  alias AshIntegration.Test.LuaBackend

  setup do
    original = Application.get_env(:ash_integration, :lua_sandbox)

    Application.put_env(:ash_integration, :lua_sandbox,
      timeout_ms: 2_000,
      max_steps: 1_000_000,
      max_heap_words: 500_000
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_integration, :lua_sandbox)
        value -> Application.put_env(:ash_integration, :lua_sandbox, value)
      end
    end)

    :ok
  end

  # A runaway loop wrapped in `pcall`, with the script carrying on afterwards.
  @pcall_bomb ~S"""
  function transform(event, defaults)
    local ok, err = pcall(function() while true do end end)
    return {caught = not ok, still_running = true}
  end
  """

  @tag timeout: 20_000
  test "a runaway loop wrapped in pcall always terminates, well inside the wall-clock ceiling" do
    # True on BOTH backends, and the part that matters most: catching the budget
    # error cannot make the run hang. The 2s wall-clock backstop is not what stops
    # it — the step budget is — so this completes far below that.
    {micros, result} = :timer.tc(fn -> Lua.execute(@pcall_bomb, %{}) end)

    assert match?({:ok, _}, result) or match?({:error, _}, result)
    assert div(micros, 1000) < 2_000
  end

  @tag timeout: 20_000
  test "what the caller sees differs by backend, and that difference is the leak" do
    result = Lua.execute(@pcall_bomb, %{})

    # Branch via `LuaBackend` (runtime detection) rather than `Compat.backend/0`
    # (a compile-time constant): see that module for why.
    if LuaBackend.luerl?() do
      # The runner process is killed mid-`pcall`. Nothing inside Lua observes it;
      # the delivery parks.
      assert {:error, message} = result
      assert message =~ "step budget" or message =~ "timed out"
    else
      # The budget error is an ordinary, catchable Lua error. The script sees it,
      # recovers, and returns a perfectly normal descriptor — which is then
      # DELIVERED. Same source, opposite outcome.
      assert {:ok, %{"caught" => true, "still_running" => true}} = result
    end
  end

  @tag timeout: 20_000
  test "catching the budget error does not refill it" do
    # The `:lua_vm` worry would be a script that loops `pcall(runaway)` forever,
    # buying unbounded CPU one caught error at a time. It cannot: the budget is
    # per top-level evaluation, so the OUTER loop's next back-edge re-raises
    # outside the pcall and the run ends in an error. On `:luerl` the first kill
    # ends it, so both backends park here.
    bomb = ~S"""
    function transform(event, defaults)
      local n = 0
      while true do
        pcall(function() while true do end end)
        n = n + 1
      end
    end
    """

    assert {:error, message} = Lua.execute(bomb, %{})
    assert message =~ "step budget" or message =~ "timed out" or message =~ "killed"
  end

  @tag timeout: 20_000
  test "a signing callback cannot pcall its way past the budget either" do
    source = ~S"""
    function string_to_sign(ctx)
      local n = 0
      while true do
        pcall(function() while true do end end)
        n = n + 1
      end
    end
    """

    assert {:error, message} =
             Lua.sign_session(source, Lua.default_limits(), fn call ->
               call.("string_to_sign", %{"body" => "payload"})
             end)

    assert message =~ "step budget" or message =~ "timed out" or message =~ "killed"
  end
end
