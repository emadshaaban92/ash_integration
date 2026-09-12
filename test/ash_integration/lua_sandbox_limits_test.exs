defmodule AshIntegration.LuaSandboxLimitsTest do
  # Not async: tightens the global `:lua_sandbox` limits to keep the bomb tests
  # fast and light.
  use ExUnit.Case, async: false

  alias AshIntegration.Outbound.Delivery.Transform.Limits
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Budget

  setup do
    original = Application.get_env(:ash_integration, :lua_sandbox)

    # Small step and heap budgets so the loop/allocation bombs die quickly and
    # cheaply — but a DELIBERATELY generous wall-clock ceiling. Every test here
    # is stopped by the step budget or the heap ceiling, both of which fire in
    # ~100ms; a tight `timeout_ms` would put the clock in a race with them, and a
    # starved scheduler could hand the win to the clock and fail an assertion
    # about the step budget for reasons having nothing to do with the budget. The
    # one test that is genuinely about the clock sets its own short timeout.
    Application.put_env(:ash_integration, :lua_sandbox,
      timeout_ms: 30_000,
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
  # The shipped default, read back through the same public surface the docs
  # promise rather than restated as a literal that could drift from it.
  defp default_max_steps, do: default_limits().max_steps

  defp default_limits do
    Application.delete_env(:ash_integration, :lua_sandbox)
    Lua.default_limits()
  end

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
    # The wall-clock backstop is a second away; the step budget is 1M, so that is
    # what fires — and the message an operator sees in `last_error` names it.
    assert {:error, message} =
             Lua.execute(~S|function transform(e, d) while true do end end|, %{})

    assert message =~ "script exceeded its step budget"
  end

  test "a host API called in a tight loop is bounded by the same budgets" do
    # Host functions are invoked by the transform Task itself — the process
    # running the Lua code — so their work and allocations count against the
    # script's ceilings. An operator can't use `datetime` to buy unbounded work.
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
    test "a limit that is not a positive integer is announced, not silently dropped" do
      # `max_steps/0` guards on `is_integer/1` — it must, since a bad value would
      # otherwise reach `Lua.new/1` — which makes its fallback to the default
      # TOTAL, and therefore silent. Without this warning an operator who wrote
      # `max_steps: "5000000"` (an env var read without `String.to_integer/1`)
      # gets the default while believing they configured a ceiling.
      Application.put_env(:ash_integration, :lua_sandbox,
        max_steps: "5000000",
        max_heap_words: 1.5
      )

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      assert log =~ "IGNORED"
      assert log =~ ~s(:max_steps: "5000000")
      assert log =~ ":max_heap_words: 1.5"
    end

    test "a well-formed config says nothing about unusable limits" do
      Application.put_env(:ash_integration, :lua_sandbox,
        timeout_ms: 5_000,
        max_steps: 1_000_000,
        max_heap_words: 200_000
      )

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      refute log =~ "IGNORED"
    end

    test "the boot warning never advises a change that would loosen the ceiling" do
      # The warning read the two keys with raw `Keyword.get` + `is_integer/1`
      # while `max_steps/0` reads them through `positive_or_nil/2`, so the two
      # disagreed. With `max_steps: 0` the warning saw two integers and advised
      # "`:max_steps` wins; drop `:max_reductions`" — but `0` is unusable, so the
      # ALIAS was the live ceiling and following that advice loosened it from
      # 1_000 to the 5_000_000 default. Advice that contradicts the code it
      # describes is worse than silence.
      Application.put_env(:ash_integration, :lua_sandbox, max_steps: 0, max_reductions: 1_000)

      assert Lua.default_limits().max_steps == 1_000, "the alias is what applies here"

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      refute log =~ "drop `:max_reductions`",
             "must not advise dropping the setting that is actually in force"

      assert log =~ "UNIT HAS CHANGED", "the alias in force is what needs explaining"
    end

    test "a clamped alias is announced even when the other key is unusable" do
      # `[max_steps: "5000", max_reductions: 100_000_000]` matched neither clause
      # of the old warning, so a clamp from 100M to the default went unmentioned.
      Application.put_env(:ash_integration, :lua_sandbox,
        max_steps: "5000",
        max_reductions: 100_000_000
      )

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      assert log =~ "UNIT HAS CHANGED"
      assert log =~ "CLAMPED"
    end

    test "the redundancy warning fires only when dropping the alias is safe" do
      # Both usable: `:max_steps` genuinely wins, so the advice holds.
      Application.put_env(:ash_integration, :lua_sandbox,
        max_steps: 1_000_000,
        max_reductions: 2_000_000
      )

      assert Lua.default_limits().max_steps == 1_000_000

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      assert log =~ "drop `:max_reductions`"
    end

    test ":max_reductions is clamped to the default, not read verbatim" do
      # `:max_steps` is new in 0.3.0, so EVERY host upgrading from an earlier
      # release configured its CPU ceiling as `:max_reductions` — in BEAM
      # reductions. Read as VM instructions those values are wrong in the
      # direction that disables the ceiling: the old default of 100_000_000 needs
      # 20s+ of CPU and can never fire before `timeout_ms`, so a runaway reports
      # "timed out" instead of naming the budget. That is the inert-budget defect
      # 0.3.0 fixed for the default, and honouring the alias verbatim would have
      # left it open for exactly the population the alias exists to serve.
      shipped_default = default_max_steps()

      Application.put_env(:ash_integration, :lua_sandbox, max_reductions: 100_000_000)

      assert Lua.default_limits().max_steps == shipped_default
    end

    test "the clamp is announced at boot, not applied silently" do
      # Quietly changing a configured ceiling would be a second surprise on top of
      # the unit change. The boot check names the value, what it became, and the
      # one-line fix.
      Application.put_env(:ash_integration, :lua_sandbox, max_reductions: 100_000_000)

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      assert log =~ "max_reductions"
      assert log =~ "UNIT HAS CHANGED"
      assert log =~ "CLAMPED"
      assert log =~ "max_steps"
    end

    test "a below-default alias is announced too, without claiming it was clamped" do
      # It is still honoured, so the warning must not say it was capped — but the
      # unit still changed underneath it, which is worth a look.
      Application.put_env(:ash_integration, :lua_sandbox, max_reductions: 500_000)

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      assert log =~ "UNIT HAS CHANGED"
      refute log =~ "CLAMPED"
    end

    test "setting both keys is called out as the redundancy it is" do
      Application.put_env(:ash_integration, :lua_sandbox,
        max_steps: 1_000_000,
        max_reductions: 2_000_000
      )

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      assert log =~ "BOTH"
      assert log =~ "drop `:max_reductions`"
    end

    test "a config using only `:max_steps` warns about nothing" do
      Application.put_env(:ash_integration, :lua_sandbox, max_steps: 1_000_000)

      log = ExUnit.CaptureLog.capture_log(fn -> Lua.warn_about_sandbox_config() end)

      refute log =~ "max_reductions"
    end

    test ":max_reductions below the default is still honoured" do
      # A value under the default was someone asking for a ceiling stricter than
      # stock. That intent survives the unit change, so the clamp must not raise
      # it — clamping in both directions would loosen a deliberately tight sandbox.
      Application.put_env(:ash_integration, :lua_sandbox, max_reductions: 500_000)
      assert Lua.default_limits().max_steps == 500_000
    end

    test ":max_steps wins over the deprecated alias and is never clamped" do
      # An explicit `:max_steps` was written in the NEW unit, so it is taken at
      # face value however large.
      Application.put_env(:ash_integration, :lua_sandbox,
        max_steps: 100_000_000,
        max_reductions: 1_000
      )

      assert Lua.default_limits().max_steps == 100_000_000
    end

    test "a limit `Lua.new/1` rejects is reported as a limits problem, not an APIs one" do
      # Both `Lua.new/1` (bad ceiling) and host-API loading (bad module) raise
      # `ArgumentError`. Building the state inside the same `try` as the API
      # reduce reported a bad LIMIT as "could not load the configured Lua host
      # APIs", sending an operator to a setting they had not touched.
      #
      # Supplied explicitly rather than through config, because config can no
      # longer produce a rejected ceiling — every `lua_sandbox` limit falls back
      # to its default when it is not a positive integer (see the tests below).
      rejected = %Limits{timeout_ms: 1_000, max_steps: 0, max_memory_words: 200_000}

      assert {:error, message} =
               Lua.execute("function transform(e, d) return d end", %{}, nil, rejected)

      assert message =~ "sandbox limits"
      assert message =~ "max_instructions"
      refute message =~ "host APIs"
    end

    test "a limit that is not a positive integer falls back to the default" do
      # Not tidiness — a safety fallback. These values are handed to
      # `Process.flag(:max_heap_size, %{size: …})` and `Task.yield(task, …)`.
      # A non-integer `:timeout_ms` used to raise `FunctionClauseError` inside
      # `Task.yield/2` — in the CALLER, taking down the delivery worker rather
      # than parking the delivery — and a bad `:max_heap_words` killed the
      # sandbox Task, reported as "sandbox crashed or was killed", which points
      # at the script instead of the config.
      #
      # `nil` is included deliberately: `Keyword.get/3` returns a stored `nil`
      # rather than its default, so `timeout_ms: nil` reached `Task.yield/2` too.
      defaults = default_limits()

      for bad <- ["5000", nil, 0, -1, 1.5] do
        Application.put_env(:ash_integration, :lua_sandbox,
          timeout_ms: bad,
          max_steps: bad,
          max_heap_words: bad
        )

        assert Lua.default_limits() == defaults,
               "expected #{inspect(bad)} to fall back to the shipped defaults"

        # And the delivery still runs rather than taking anything down with it.
        assert {:ok, :skip} = Lua.execute("function transform(e, d) return nil end", %{})
      end
    end

    test ":max_steps sets the step budget" do
      Application.put_env(:ash_integration, :lua_sandbox, max_steps: 12_345)
      assert Lua.default_limits().max_steps == 12_345
    end

    test ":max_reductions is still honoured as the deprecated alias" do
      # It named the flag `lua 0.4`'s luerl backend used, which this runtime no
      # longer runs on — but a host that set it must keep its configured ceiling
      # rather than silently reverting to the (much larger) default.
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

  describe "the shipped defaults" do
    # `guides/delivery-pipeline.md` repeats the `lua_sandbox` block as copy-paste
    # config and, being markdown, cannot interpolate the real defaults the way the
    # runtime moduledoc now does. It has gone stale before — the defaults were
    # re-tuned in code while the guide kept the old numbers, so a host pasting it
    # got a sandbox behaving differently from the one the docs describe.
    @documented_guide "guides/delivery-pipeline.md"

    @documented_keys [
      {"timeout_ms", :timeout_ms},
      {"max_steps", :max_steps},
      {"max_heap_words", :max_memory_words}
    ]

    test "the guide's `lua_sandbox` block matches the real defaults" do
      # A prose guard, deliberately. The interesting failure is not a wrong number
      # in the abstract — it is an operator pasting a documented block and quietly
      # getting a different sandbox. Nothing else in the suite reads the docs.
      Application.delete_env(:ash_integration, :lua_sandbox)
      defaults = Lua.default_limits()

      # The `lua_sandbox: [ ... ]` block itself, not the whole file: the guide also
      # mentions these keys in prose, and matching the first occurrence anywhere
      # would pin the wrong number the moment one of those moves.
      source = File.read!(Path.join(File.cwd!(), @documented_guide))

      block =
        case Regex.run(~r/lua_sandbox:\s*\[(.*?)\]/s, source) do
          [_, block] -> block
          nil -> flunk("#{@documented_guide} has no `lua_sandbox: [...]` config block")
        end

      for {key, field} <- @documented_keys do
        expected = Map.fetch!(defaults, field)

        documented =
          case Regex.run(~r/#{key}:\s+([\d_]+)/, block) do
            [_, captured] -> captured |> String.replace("_", "") |> String.to_integer()
            nil -> flunk("#{@documented_guide} documents no `#{key}:` value at all")
          end

        assert documented == expected,
               "#{@documented_guide} documents `#{key}: #{documented}` but the shipped " <>
                 "default is #{expected} — an operator pasting that block gets a " <>
                 "different sandbox than the docs describe"
      end
    end

    @tag timeout: 60_000
    test "the default step budget stops a tight loop well inside the default timeout" do
      # A REGRESSION GUARD, not a limits test — the tightened budgets from `setup`
      # are deliberately dropped so this runs on what a host actually gets.
      #
      # Before 0.3.0 `max_steps` counted BEAM reductions, where 100_000_000 was
      # the right order of magnitude. As `lua 1.0` VM instructions the same number
      # needs 20s+ of CPU, so it could never fire before the 5s `timeout_ms` and
      # the step budget was inert at stock config: every runaway was stopped by
      # the coarse wall-clock backstop instead, with "timed out" in `last_error`.
      #
      # This asserts the ORDERING that makes the deterministic ceiling meaningful:
      # the budget fires first, and says so.
      Application.delete_env(:ash_integration, :lua_sandbox)
      defaults = Lua.default_limits()

      # MEASURED, not raced. Running this under the default `timeout_ms` would
      # make the two ceilings compete, and on a starved scheduler the clock can
      # win — turning a real ordering guarantee into a load-dependent test. So
      # the run gets a deliberately generous clock, and the ordering is then
      # asserted on how long budget exhaustion actually took versus the real
      # default. Same property, no race.
      unraced = %Limits{defaults | timeout_ms: 60_000}
      loop = ~S|function transform(e, d) while true do end end|

      {micros, result} = :timer.tc(fn -> Lua.execute(loop, %{}, nil, unraced) end)

      assert {:error, message} = result
      assert message =~ "exceeded its step budget"

      # The ordering that makes the deterministic ceiling meaningful: exhausting
      # the default budget must finish well inside the default wall-clock
      # ceiling, with room for slower CI hardware. At the pre-0.3.0 value this is
      # ~20s against a 5s ceiling and fails loudly here.
      elapsed = div(micros, 1000)

      assert elapsed < div(defaults.timeout_ms, 2),
             "the default step budget takes #{elapsed}ms to exhaust, which is not " <>
               "comfortably inside the default #{defaults.timeout_ms}ms wall-clock " <>
               "ceiling — at stock config the budget would lose the race and every " <>
               "runaway would report `timed out` instead of naming the budget"
    end
  end

  describe "the sandbox has no ambient clock" do
    test "every clock function refuses its no-argument (ambient) form" do
      # Driven off the real list so a path added to `Budget` is covered here
      # without anyone remembering to restate it. Called with no arguments, every
      # entry reads a clock — including the ones whose argument form is allowed.
      for {path, _min_args} <- Budget.clock_paths() do
        call = Enum.map_join(path, ".", &Atom.to_string/1)

        assert {:error, message} =
                 Lua.execute("function transform(e, d) return {v = #{call}()} end", %{}),
               "expected #{call}() to be refused"

        assert message =~ "sandboxed", "#{call}(): #{message}"
      end
    end

    test "an argument that is present but unusable is still refused" do
      # THE regression this suite missed for four review rounds. The guard used to
      # count arguments, and every test here passed zero — so `os.time(nil)`,
      # `os.date(fmt, nil)` and `os.date(fmt, "x")` all satisfied the check and
      # returned the live wall clock, defeating the whole invariant.
      #
      # The VM decides by VALUE, in a specific position: `os_time/2` uses its
      # first argument only when it is a table, and `os_date/2` its second only
      # `when is_number(t)`. Anything else falls through to `System.os_time/1`.
      refused = [
        ~S|os.time(nil)|,
        ~S|os.time("2024-06-15")|,
        ~S|os.time(1718447400)|,
        ~S|os.time(true)|,
        ~S|os.date("!%Y-%m-%d", nil)|,
        ~S|os.date("!%Y-%m-%d", "1718447400")|,
        ~S|os.date("!%Y-%m-%d", false)|,
        ~S|os.date("!%Y-%m-%d", {})|
      ]

      for call <- refused do
        assert {:error, message} =
                 Lua.execute("function transform(e, d) return {v = tostring(#{call})} end", %{}),
               "#{call} must be refused — it reads the clock"

        assert message =~ "sandboxed", "#{call}: #{message}"
      end
    end

    test "no refused form can return a clock reading" do
      # The property, asserted end to end rather than inferred from the guard: if
      # any refusal leaked, two runs a second apart would differ. Run the whole
      # refused set twice and require every call to fail both times.
      calls = [~S|os.time(nil)|, ~S|os.date("!%c", nil)|, ~S|os.date("!%c", "x")|, ~S|os.time()|]

      run = fn ->
        Enum.map(calls, fn call ->
          Lua.execute("function transform(e, d) return {v = tostring(#{call})} end", %{})
        end)
      end

      first = run.()
      Process.sleep(1_100)

      assert Enum.all?(first, &match?({:error, _}, &1))
      assert Enum.map(first, &elem(&1, 0)) == Enum.map(run.(), &elem(&1, 0))
    end

    test "the argument-driven forms still work — they are pure, not ambient" do
      # The ban is on READING a clock, not on time handling. These take the
      # instant as an argument, so they reproduce exactly on a replay or a retry.
      # Blocking them would also leave nowhere to go: `datetime` requires an
      # ISO-8601 string with an offset, so a transform rendering a Unix timestamp
      # out of `event.data` would have no route at all.
      assert {:ok, %{"v" => "2024-06-15T10:30:00Z"}} =
               Lua.execute(
                 ~S|function transform(e, d) return {v = os.date("!%Y-%m-%dT%H:%M:%SZ", e.t)} end|,
                 %{"t" => 1_718_447_400}
               )

      assert {:ok, %{"v" => 1_718_447_400}} =
               Lua.execute(
                 ~S|function transform(e, d) return {v = os.time({year=2024, month=6, day=15, hour=10, min=30, sec=0}) } end|,
                 %{}
               )
    end

    test "an allowed time call returns the same bytes on every run" do
      # The property the ban exists to protect, asserted directly rather than
      # inferred from which functions are reachable: a transform is replayed on
      # reprocess and a signing callback re-runs per attempt.
      src = ~S|function transform(e, d) return {v = os.date("!%Y-%m-%d %H:%M:%S", e.t)} end|

      results = for _ <- 1..3, do: Lua.execute(src, %{"t" => 1_718_447_400})

      assert [{:ok, %{"v" => "2024-06-15 10:30:00"}}] = Enum.uniq(results)
    end

    test "the refusal explains what to do instead" do
      # An operator hitting this after an upgrade needs the alternative, not just
      # a denial — the argument form is right there and easy to miss.
      assert {:error, message} =
               Lua.execute(~S|function transform(e, d) return {v = os.time()} end|, %{})

      assert message =~ "read the clock"
      assert message =~ "ctx.now"
      assert message =~ "datetime"
      # Names the shape that is missing, not just the rule — the argument may be
      # present but nil or the wrong type, which "is sandboxed" alone hides.
      assert message =~ "os.time({year"
    end

    test "a signing callback cannot read the clock either" do
      # The sharper case: a callback reading the clock signs different bytes on
      # every delivery attempt, defeating the frozen `ctx.now` the scheme exists
      # to provide. Same state builder, but pin it on the path that matters.
      source = ~S|function string_to_sign(ctx) return tostring(os.time()) end|

      assert {:error, message} =
               Lua.sign_session(source, Lua.default_limits(), fn call ->
                 call.("string_to_sign", %{"body" => "payload"})
               end)

      assert message =~ "sandboxed"
    end

    test "os.difftime survives — it is arithmetic over values passed in" do
      # The clock ban is about reading an ambient clock, not about time math.
      # Over-blocking here would push authors back to hand-rolled arithmetic.
      assert {:ok, %{"d" => 60.0}} =
               Lua.execute(
                 ~S|function transform(e, d) return {d = os.difftime(100, 40)} end|,
                 %{}
               )
    end

    test "the datetime host API still works on a timestamp passed in" do
      assert {:ok, %{"t" => "2024-06-15T13:30:00+03:00"}} =
               Lua.execute(
                 ~S|function transform(e, d) return {t = datetime.to_zone(e.at, "Africa/Cairo")} end|,
                 %{"at" => "2024-06-15T10:30:00Z"}
               )
    end
  end

  describe "the sandbox ceilings" do
    test "the runtime runs on a `lua` release that offers the VM limit options" do
      # `mix.exs` requires `~> 1.0`. The ceilings `Budget` sets — `:max_instructions`,
      # `:max_call_depth`, `:max_string_bytes` — are all `lua 1.0` options; `0.4`
      # accepted none of them and `Lua.new/1` would raise on every one. Pin the
      # floor so a resolution that somehow went backwards fails here, loudly,
      # rather than at the first delivery.
      assert Version.match?(to_string(Application.spec(:lua, :vsn)), "~> 1.0")
    end

    test "runaway recursion is refused outright, not left to the heap ceiling" do
      # `Budget` sets `:max_call_depth`, which `lua 0.4` had no equivalent for —
      # there, unbounded recursion was caught by the reduction and heap ceilings
      # instead, i.e. by whichever happened to trip first. Now it is a
      # deterministic refusal, which the VM reports as a stack overflow.
      runaway = ~S"""
      function transform(event, defaults)
        local function down(n) return 1 + down(n + 1) end
        return {n = down(1)}
      end
      """

      assert {:error, message} = Lua.execute(runaway, %{})
      assert message =~ "stack overflow"
    end

    @tag timeout: 30_000
    test "the wall-clock ceiling is the configured one" do
      # The VM has no inner timer, so the outer Task waits exactly `timeout_ms`
      # and no grace beyond it. A blocking host call is the one case that reaches
      # the Task's timer with the step budget unable to fire, which is precisely
      # what makes this measurable.
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
