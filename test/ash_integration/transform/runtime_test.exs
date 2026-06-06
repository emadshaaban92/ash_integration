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
      assert %Limits{
               timeout_ms: timeout_ms,
               max_steps: max_steps,
               max_memory_words: max_memory_words
             } = Lua.default_limits()

      assert is_integer(timeout_ms) and timeout_ms > 0
      assert is_integer(max_steps) and max_steps > 0
      assert is_integer(max_memory_words) and max_memory_words > 0
    end

    test "execute/4 honors an explicitly supplied tighter step budget" do
      tight = %Limits{timeout_ms: 1_000, max_steps: 1_000_000, max_memory_words: 200_000}

      assert {:error, message} = Lua.execute("while true do end", %{}, nil, tight)
      assert message =~ "reduction" or message =~ "timed out"
    end
  end
end
