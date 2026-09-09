defmodule AshIntegration.LuaPcallBudgetTest do
  # Not async: tightens the global `:lua_sandbox` limits so the runaway loops die
  # quickly.
  use ExUnit.Case, async: false

  @moduledoc """
  A script cannot `pcall` its way past the step budget and still deliver.

  The VM raises a budget breach as an **ordinary Lua error**, so `pcall` catches
  it. Left alone that would let a transform wrap its body in `pcall`, burn its
  entire budget, swallow the error, and return a normal descriptor — which would
  then be delivered. Total CPU is bounded either way (the budget is per top-level
  evaluation and a caught breach is never refunded), but the invariant operators
  rely on is stronger than that: reaching the ceiling **parks the delivery**.

  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Budget` enforces it by
  checking the instruction tally on the way out of a successful evaluation as
  well as a failed one. Transform sources are operator-authored but untrusted at
  runtime, so this is a security property, not a curiosity — these tests are what
  keep it from regressing into "the script noticed, so we shipped its result".
  """

  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Budget

  setup do
    original = Application.get_env(:ash_integration, :lua_sandbox)

    # Tight step budget, generous clock. These tests assert on the STEP BUDGET
    # message, and exhausting 1M instructions takes ~100ms — so a tight
    # `timeout_ms` would leave only ~10x of margin and let a starved scheduler
    # turn "the budget stopped it" into "the clock stopped it". The one test that
    # compares the two keeps its own explicit bound.
    Application.put_env(:ash_integration, :lua_sandbox,
      timeout_ms: 30_000,
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
  test "a runaway loop wrapped in pcall is stopped by the step budget, not the clock" do
    # The part that matters most: catching the budget error cannot make the run
    # hang. The step budget is what ends it, so this finishes far inside the
    # (deliberately generous, see `setup`) wall-clock ceiling — which, being the
    # only wall-clock enforcement point, is what the run would hit if the budget
    # could not stop a script that catches its breach.
    {micros, result} = :timer.tc(fn -> Lua.execute(@pcall_bomb, %{}) end)

    assert {:error, _message} = result

    # Exhausting the budget takes ~100ms; the bound is loose enough to survive a
    # loaded CI box while still being nowhere near the 30s ceiling, so a run that
    # actually fell through to the clock cannot pass.
    elapsed = div(micros, 1000)

    assert elapsed < 5_000, "expected the step budget to end this, not the clock (#{elapsed}ms)"
  end

  @tag timeout: 20_000
  test "the swallowed breach parks the delivery instead of returning the script's result" do
    # The script itself succeeds: it catches the error and returns a perfectly
    # well-formed descriptor. What must NOT happen is that descriptor reaching the
    # transport — the run spent its whole budget, so it is a resource-limit
    # failure whether or not the script noticed.
    assert {:error, message} = Lua.execute(@pcall_bomb, %{})
    assert message =~ "exceeded its step budget"

    # And the diagnostic says why an apparently-successful script parked, so an
    # operator is not left hunting a runaway that "returned fine".
    assert message =~ "caught"
  end

  test "an expensive but honest script is not mistaken for a swallowed breach" do
    # The other side of the exhaustion check: it must fire only at the ceiling.
    # `State.tick!/2` raises AT the budget, so a run that completes is always
    # strictly under it — but a check written as `>` vs `>=`, or one reading a
    # stale tally, would misfire here and park legitimate traffic.
    Application.put_env(:ash_integration, :lua_sandbox,
      timeout_ms: 2_000,
      max_steps: 50_000,
      max_heap_words: 500_000
    )

    busy = ~S"""
    function transform(event, defaults)
      local sum = 0
      for i = 1, 9000 do sum = sum + i end
      return {sum = sum}
    end
    """

    assert {:ok, %{"sum" => 40_504_500}} = Lua.execute(busy, %{})
  end

  describe "an unreadable instruction tally" do
    test "is treated as a breach, not as 'no breach'" do
      # The decision this pins cannot be produced through the real VM, so it is
      # tested where it is made. Answering `:within` for a tally we could not read
      # would silently reopen the pcall-swallow hole: the run SUCCEEDED, and we
      # would be shipping its result on the strength of a check that did not run.
      assert Budget.budget_outcome(:unknown) == :unverifiable
    end

    test "is the only outcome that fails closed" do
      # The rest of the table, so a future edit cannot quietly widen `:within`.
      assert Budget.budget_outcome({0, 5_000}) == :within
      assert Budget.budget_outcome({4_999, 5_000}) == :within
      assert Budget.budget_outcome({5_000, 5_000}) == :exhausted
      assert Budget.budget_outcome({5_001, 5_000}) == :exhausted
    end

    test "the counters it reads are still where the VM keeps them" do
      # The tripwire for the risk above: `mix.exs` accepts `lua ~> 1.0` and
      # nothing pins these field names, so a 1.x release that renames them is an
      # ordinary dependency bump. Without this the first symptom would be every
      # transform refusing at runtime; with it, the bump fails here instead.
      state = Budget.new_state(Lua.default_limits()).state

      assert is_integer(state.instruction_count)
      assert is_integer(state.max_instructions)
    end
  end

  test "a script cannot forge a step-budget failure by raising the marker itself" do
    # The `:lua_vm` backend raises the budget breach as an ordinary Lua error, so
    # the runtime has to tell a real breach from a script quoting it. `error/2` at
    # level 0 suppresses the position prefix, reproducing the VM's own marker byte
    # for byte — if the runtime matched on the message, this source would fabricate
    # a resource-limit failure and bury its real diagnostic, sending an operator
    # after a runaway loop that never happened.
    forge = ~S"""
    function transform(event, defaults)
      error("instruction budget exceeded", 0)
    end
    """

    assert {:error, message} = Lua.execute(forge, %{})

    # The script's own error reaches `last_error`...
    assert message =~ "instruction budget exceeded"
    # ...but it is NOT reported as a resource limit, on either backend.
    refute message =~ "exceeded its step budget"
  end

  test "a real breach is still reported as one, right beside the forgery" do
    # The other half of the pair: the discriminator must not be so strict that a
    # genuine breach stops being recognised.
    assert {:error, message} =
             Lua.execute(~S|function transform(e, d) while true do end end|, %{})

    assert message =~ "exceeded its step budget"
  end

  @tag timeout: 20_000
  test "catching the budget error does not refill it" do
    # The `:lua_vm` worry would be a script that loops `pcall(runaway)` forever,
    # buying unbounded CPU one caught error at a time. It cannot: the budget is
    # per top-level evaluation, so the OUTER loop's next back-edge re-raises
    # outside the pcall and the run ends in an error.
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
