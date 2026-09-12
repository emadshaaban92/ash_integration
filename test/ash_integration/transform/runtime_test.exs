defmodule AshIntegration.Transform.RuntimeTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua
  alias AshIntegration.Outbound.Delivery.Transform.Runtime
  alias AshIntegration.Outbound.Delivery.Transform.Limits

  describe "default_runtime/0 and impl!/1" do
    test "the default runtime resolves to the Lua sandbox" do
      assert Runtime.default_runtime() == :lua
      assert Runtime.impl!(:lua) == Lua
    end

    test "an unknown runtime tag raises (closed, compile-time set)" do
      assert_raise ArgumentError, ~r/unknown transform runtime/, fn ->
        Runtime.impl!(:brainfuck)
      end
    end

    test "the default runtime is one of the known runtimes" do
      assert Runtime.default_runtime() in Runtime.runtimes()
    end

    # Drift guard: the subscription's `transform_runtime` `one_of` derives from
    # `runtimes/0`, so a persistable runtime that doesn't resolve here would crash
    # the resolver at delivery instead of parking cleanly. Keep them in lockstep.
    test "every persistable runtime resolves to a usable implementation" do
      for runtime <- Runtime.runtimes() do
        impl = Runtime.impl!(runtime)
        assert Code.ensure_loaded?(impl)
        assert function_exported?(impl, :execute, 4), "#{inspect(impl)} must implement execute/4"

        assert function_exported?(impl, :default_limits, 0),
               "#{inspect(impl)} must implement default_limits/0"
      end
    end
  end

  describe "execute/4 dispatch" do
    test "runs a transform on the named runtime with its default limits" do
      script = ~S"""
      function transform(event, defaults)
        return {name = event.name, doubled = event.count * 2}
      end
      """

      assert {:ok, %{"name" => "test", "doubled" => 10}} =
               Runtime.execute(:lua, script, %{"name" => "test", "count" => 5}, nil)
    end

    test "pre-seeded defaults pass through when the source exposes no transform" do
      # No-op script: the pre-seeded defaults survive untouched.
      assert {:ok, %{"method" => "post", "path" => "/hook"}} =
               Runtime.execute(:lua, "", %{}, %{"method" => "post", "path" => "/hook"})
    end

    test "a source with no transform (and no defaults) skips" do
      assert {:ok, :skip} = Runtime.execute(:lua, "local x = 1", %{}, nil)
    end

    test "errors surface as {:error, message}" do
      assert {:error, message} =
               Runtime.execute(:lua, "function transform(e, d) return {", %{}, nil)

      assert is_binary(message)
    end
  end

  describe "validate/2" do
    test "accepts a well-formed script" do
      assert :ok = Runtime.validate(:lua, "function transform(e, d) return {ok = true} end")
    end

    test "rejects a script that does not parse (syntax error caught at save)" do
      assert {:error, message} = Runtime.validate(:lua, "result = {")
      assert message =~ "does not parse"

      # The backend's own diagnostic has to reach the operator. `Lua.parse_chunk/1`
      # is one of the two places the two `lua` releases disagree: `0.4` answers
      # `{:error, [String.t()]}`, `1.0` answers `{:error, %Lua.CompilerException{}}`
      # — and `to_string/1` on an exception struct raises, so a single-shape
      # formatter would crash here rather than degrade.
      assert String.length(message) > String.length("script does not parse: ")
      refute message =~ "Lua.CompilerException"
    end

    test "accepts a script that parses but raises at runtime (it parks at dispatch)" do
      # Early validation stops at "does it parse"; a runtime error is the
      # platform's job to handle later (park + reprocess), not to reject here.
      assert :ok = Runtime.validate(:lua, "error('boom')")
    end

    test "rejects an oversized script before save" do
      assert {:error, message} = Runtime.validate(:lua, String.duplicate("x", 10_241))
      assert message =~ "maximum size"
    end
  end

  describe "Lua implements the behaviour contract" do
    test "default_limits/0 reflects the runtime-neutral vocabulary" do
      limits = Lua.default_limits()

      assert %Limits{} = limits

      # Read each field through a variable key. Binding them out of the struct
      # directly lets Elixir 1.20's type checker narrow a field it can prove is
      # an integer — `max_steps/0` is total, so it does — and then flag the
      # `is_integer/1` here as an always-true guard, failing the suite under
      # `--warnings-as-errors` on 1.20 while passing on 1.19. The check is still
      # worth making: the other two come from config and are NOT statically
      # known, so this is a real assertion for them and cheap insurance for
      # `max_steps` if its derivation ever loosens again.
      for field <- [:timeout_ms, :max_steps, :max_memory_words] do
        value = Map.fetch!(limits, field)

        assert is_integer(value) and value > 0,
               "expected #{field} to be a positive integer, got: #{inspect(value)}"
      end
    end

    test "execute/4 honors an explicitly supplied tighter step budget" do
      # `timeout_ms` is deliberately generous. What this pins is that an
      # explicitly supplied `max_steps` is the ceiling that applies — not that it
      # beats the clock. Exhausting 1M instructions takes ~100ms, so a 1s
      # wall-clock ceiling made the two race with only ~10x of margin, and under
      # enough scheduler starvation the clock won and the assertion below failed
      # spuriously. Widening the margin removes a failure mode the test was never
      # about; the ordering of the two ceilings at STOCK config is pinned
      # separately, and deterministically, in `lua_sandbox_limits_test.exs`.
      tight = %Limits{timeout_ms: 30_000, max_steps: 1_000_000, max_memory_words: 200_000}

      assert {:error, message} = Lua.execute("while true do end", %{}, nil, tight)
      # `Limits` vocabulary, not the VM's native unit: it counts instructions,
      # but the breach an operator sees is reported as the step budget.
      assert message =~ "exceeded its step budget"
    end
  end
end
