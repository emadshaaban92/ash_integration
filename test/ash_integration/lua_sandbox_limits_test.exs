defmodule AshIntegration.LuaSandboxLimitsTest do
  # Not async: tightens the global `:lua_sandbox` limits to keep the bomb tests
  # fast and light.
  use ExUnit.Case, async: false

  alias AshIntegration.Outbound.Delivery.LuaSandbox

  setup do
    original = Application.get_env(:ash_integration, :lua_sandbox)

    # Small budgets so the allocation/loop bombs die quickly and cheaply.
    Application.put_env(:ash_integration, :lua_sandbox,
      timeout_ms: 1_000,
      max_reductions: 1_000_000,
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

  test "an allocation-bomb script is killed without taking down the caller" do
    bomb = ~S"""
    local t = {}
    local i = 1
    while true do
      t[i] = string.rep("x", 1024)
      i = i + 1
    end
    """

    assert {:error, message} = LuaSandbox.execute(bomb, %{})
    assert is_binary(message)

    # The caller (this test process) is unharmed and the sandbox still works for a
    # well-behaved script afterwards — proving crash isolation + recovery.
    assert {:ok, %{"ok" => true}} = LuaSandbox.execute(~S|result = {ok = true}|, %{})
  end

  test "a tight infinite loop is killed by the reduction budget" do
    assert {:error, message} = LuaSandbox.execute("while true do end", %{})
    assert is_binary(message)
    assert message =~ "reduction" or message =~ "timed out"
  end

  test "a legitimate script still runs under the tightened budgets" do
    assert {:ok, %{"doubled" => 84}} =
             LuaSandbox.execute(~S|result = {doubled = event.n * 2}|, %{"n" => 42})
  end
end
