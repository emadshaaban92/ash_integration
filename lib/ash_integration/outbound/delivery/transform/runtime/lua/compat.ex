defmodule AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat do
  # Loaded at COMPILE time so the version test below is a compile-time constant.
  # `mix compile` puts every dependency on the code path but does not necessarily
  # *load* its application, and `Application.spec/2` answers `nil` for an unloaded
  # app — which would silently select the wrong branch.
  _ = :application.load(:lua)

  @lua_vsn (case Application.spec(:lua, :vsn) do
              nil ->
                raise "could not read the :lua application version — " <>
                        "AshIntegration selects its Lua backend from it at compile time"

              vsn ->
                to_string(vsn)
            end)

  # Detect on the `:lua` application's VERSION, never on
  # `Code.ensure_loaded?(:luerl_sandbox)`. `mix.exs` declares `:luerl` directly
  # (`lua 1.0` has no luerl dependency of its own, and the 0.4 path calls
  # `:luerl_sandbox` — an undeclared dependency until now), so the module is
  # loadable on a `lua 1.0` install too. A presence probe would happily hand
  # `:luerl_sandbox.run/3` a `%Lua.VM.State{}` and fail at every delivery.
  #
  # Both branches are exercised in CI (see the `lua` dimension of
  # `.github/workflows/ci.yml`), and that coverage is verifiable: negate this
  # test and run the Lua suite under each lockfile. The 0.4 tree compiled with the
  # 1.0 branch fails to COMPILE (the branch matches on `Lua.RuntimeException`
  # fields 0.4's struct does not have), and the 1.0 tree compiled with the 0.4
  # branch goes red with 61 failures. A version shim whose dead branch is never
  # exercised is not covered.
  # `">= 1.0.0-0"`, not `">= 1.0.0"`: Elixir's `Version.match?/2` excludes
  # pre-releases from a requirement that carries none, so `1.0.0-rc.1` would test
  # FALSE against `">= 1.0.0"` and compile the `:luerl` branch — the exact failure
  # this gate exists to prevent. `mix.exs` accepts `~> 1.0`, which Hex resolves to
  # a published `1.0.0-rc`, so it is reachable without anyone touching the
  # constraint. `test/support/lua_backend.ex` re-derives the backend at run time
  # and must use the same requirement.
  @v1 Version.match?(@lua_vsn, ">= 1.0.0-0")

  @moduledoc """
  The **only** version-specific surface between
  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua` and the `lua` package.

  `lua 0.4` is a wrapper around Erlang's luerl; `lua 1.0` replaced luerl with its
  own Elixir-native Lua 5.3 VM and dropped luerl as a dependency entirely.
  Everything the transform runtime needs is spelled identically in both releases
  — `Lua.new/1`, `Lua.load_api/2`, `use Lua.API`/`deflua`, `Lua.encode!/2`,
  `Lua.set!/3`, `Lua.eval!/2`, `Lua.get!/2`, `Lua.RuntimeException`,
  `Lua.CompilerException` — with **one** exception: how you put a CPU ceiling on
  an evaluation. That has no overlap at all, and it is what this module isolates.

  This node runs on `lua #{@lua_vsn}` (`#{if @v1, do: ":lua_vm", else: ":luerl"}`
  backend — see `backend/0`).

  ## The CPU bound has no common spelling

  | | `lua 0.4` | `lua 1.0` |
  | --- | --- | --- |
  | Where the ceiling lives | `:luerl_sandbox.run/3`'s flags | `Lua.new/1`'s options |
  | Unit | BEAM **reductions** of the runner process | **VM instructions** of the evaluation |
  | Sampling | coarse polling of `process_info(runner, :reductions)` | deterministic, at loop back-edges and call boundaries |
  | Enforcement | the luerl runner process is **killed** | a Lua error is **raised** |
  | Script-observable? | **no** — a killed process cannot run `pcall` | **yes** — "recoverable via `pcall`" |

  `lua 0.4` offers no ceiling anywhere else: its `Lua.new/1` is
  `Keyword.validate!(opts, sandboxed:, exclude:)` — no limit options — and its
  `Lua.eval!/3` calls `:luerl.do_dec/2` with no budget. So on 0.4 the limit
  mechanism *is* the execution call, and `eval/4` here must be the execution call
  too rather than a wrapper that adds limits beside `Lua.eval!/2`.

  ## The leak this module cannot close

  Transform sources are **operator-authored but untrusted at runtime**, so the
  last row of that table is a real difference in the security story, not an
  implementation detail:

  - On the **`:luerl`** backend, a script that wraps its body in `pcall` is
    bounded exactly like one that does not. The budget is enforced by killing the
    process the Lua code runs in; nothing inside Lua can observe or survive it,
    so the run always ends in `{:error, …}` and the delivery parks.
  - On the **`:lua_vm`** backend, `pcall` **catches** the budget error. Total CPU
    is still bounded — the budget is per top-level evaluation and is *not*
    refilled, so a script cannot buy more work by catching it, and the very next
    loop back-edge re-raises — but a script can burn its whole budget, catch the
    error, and go on to **return a normal result**. The same source that parks on
    0.4 can deliver on 1.0.

  `AshIntegration.Outbound.Delivery.Transform.Limits` deliberately does not paper
  over this: `:max_steps` names *a* work budget, and each backend's enforcement
  point is documented where it differs. `test/ash_integration/lua_pcall_budget_test.exs`
  pins the behaviour of both.

  ## Wall-clock is the caller's Task, on BOTH backends

  It is tempting to say `lua 0.4` has a wall-clock ceiling of its own and
  `lua 1.0` does not. It does not, in any way the runtime can use.

  `lua 0.4` does expose a `max_time` flag, but `luerl_sandbox:do_run/3` only
  honours it when `max_reductions` is **unset**:

      case proplists:get_value(max_reductions, Flags) of
          none -> receive_response(Runner, MaxT);
          MaxR -> case wait_reductions(Runner, MaxR) of
                      {killed, R} -> {error, {reductions, R}};
                      ok          -> receive_response(Runner, MaxT)
                  end
      end

  `wait_reductions/2` returns only once the runner has died or been killed for
  exceeding its reductions, so by the time `receive_response(Runner, MaxT)` is
  reached the reply is already in the mailbox and `MaxT` bounds nothing. The
  runtime always sets a step budget, so that branch is always the one taken. (A
  *blocking* runner never advances its reduction count either, so it loops inside
  `wait_reductions/2` and never reaches the timer at all — see the blocking
  host-function note in `Runtime.Lua`.)

  `flags/1` still passes `max_time` — it costs nothing and would be a live
  ceiling if the step budget were ever unset — but the outer `Task` in
  `Runtime.Lua.execute/4` is the real and only wall-clock enforcement point on
  both backends. It therefore waits exactly `Limits.timeout_ms`, with no grace
  added for an inner timer that never fires.

  ## Memory changes enforcement point

  `lua 0.4` carries `:max_heap_size` into the luerl runner via `spawn_opts`;
  `lua 1.0` evaluates in the calling process, so the caller's own
  `Process.flag(:max_heap_size, …)` is what bounds it. The runtime sets that flag
  on its `Task` on both backends, so the ceiling holds either way.

  That in-process evaluation is also an upside worth recording: on the `:lua_vm`
  backend `Task.shutdown(task, :brutal_kill)` actually kills the evaluator, so
  the 0.4 hazard where a **blocking** host function leaks one unlinked luerl
  runner per delivery simply does not exist.

  ## Extra ceilings the VM backend offers

  `lua 1.0` also accepts `:max_call_depth` and `:max_string_bytes`, which `lua 0.4`
  has no equivalent for (there, unbounded recursion and single-string allocation
  bombs are caught by the reduction and heap ceilings instead). `new_state/1`
  sets both from the same `Limits`, so the VM backend is bounded at least as
  tightly as luerl rather than less — see `new_state/1`.
  """

  alias AshIntegration.Outbound.Delivery.Transform.Limits

  # Shared vocabulary for the one condition both backends can hit but spell
  # differently. Kept in `Limits` terms ("step budget"), with the backend's own
  # unit in the parenthetical so an operator reading `last_error` can still tell
  # what actually stopped the script.
  @step_budget_phrase "exceeded its step budget"

  @typedoc "Which `lua` release this node compiled against."
  @type backend :: :lua_vm | :luerl

  @doc """
  `:lua_vm` on `lua 1.0` (its own Elixir Lua VM), `:luerl` on `lua 0.4` (Erlang
  luerl). Fixed at compile time. Tests that must assert per-backend behaviour
  branch on this rather than on a version string.
  """
  @spec backend() :: backend()
  if @v1 do
    def backend, do: :lua_vm
  else
    def backend, do: :luerl
  end

  @doc "The `:lua` application version this node compiled against."
  @spec lua_version() :: String.t()
  def lua_version, do: @lua_vsn

  if @v1 do
    @instruction_budget_marker "instruction budget exceeded"

    # Deep enough for any plausible transform (real Lua errors at ~200 nested C
    # calls), shallow enough that runaway recursion is refused outright instead of
    # being left to the heap ceiling. `lua 0.4` has no equivalent option.
    @max_call_depth 1_000

    @doc """
    A fresh sandboxed `t:Lua.t/0` carrying `limits`' CPU ceiling.

    On this backend the ceiling is `:max_instructions`, set once on the state and
    fresh per top-level evaluation. Two ceilings `lua 0.4` cannot express are set
    from the same `Limits` rather than left at their (`:infinity`/256 MiB)
    defaults, so the VM backend is bounded at least as tightly as luerl:

      * `:max_call_depth` — #{@max_call_depth} frames. luerl bounds runaway
        recursion only via reductions and heap; here it is refused outright.
      * `:max_string_bytes` — a quarter of `:max_memory_words` (as bytes). The
        `lua 1.0` default permits a single string large enough to trip a smaller
        heap ceiling *mid-allocation*, where the kill depends on GC timing;
        sizing it under the heap cap turns the single-string bomb into a
        deterministic refusal and leaves the heap ceiling as the backstop for
        aggregate allocation.
    """
    @spec new_state(Limits.t()) :: Lua.t()
    def new_state(%Limits{} = limits) do
      Lua.new(
        max_instructions: limits.max_steps,
        max_call_depth: @max_call_depth,
        max_string_bytes: max_string_bytes(limits)
      )
    end

    # A quarter of the heap ceiling, in bytes (`:max_memory_words` counts 8-byte
    # BEAM words). Floor of 1 byte keeps `Lua.new/1`'s positive-integer validation
    # happy for absurdly small configured heaps.
    defp max_string_bytes(%Limits{max_memory_words: words}), do: max(div(words * 8, 4), 1)

    @doc """
    Evaluate `source` on `lua`, bounded by `limits`, returning the threaded
    `t:Lua.t/0` so the caller can read globals back out of it.

    `subject` ("script", "signing callback", …) names what ran, for the
    resource-limit messages only.

    On this backend the CPU ceiling was already baked into the state by
    `new_state/1`, so this is plain `Lua.eval!/2` with its exceptions classified.
    """
    @spec eval(Lua.t(), String.t(), Limits.t(), String.t()) ::
            {:ok, Lua.t()} | {:error, String.t()}
    def eval(%Lua{} = lua, source, %Limits{} = limits, subject \\ "script") do
      {_results, lua} = Lua.eval!(lua, source)
      {:ok, lua}
    rescue
      e in [Lua.RuntimeException, Lua.CompilerException] ->
        {:error, classify(e, limits, subject)}
    end

    # `lua 1.0` raises the CPU bound as an ordinary Lua error, so it has to be
    # told apart from every other one. Translated into the same `Limits`
    # vocabulary the `:luerl` branch produces, one condition reads as one message
    # on both backends.
    defp classify(%Lua.RuntimeException{} = e, %Limits{} = limits, subject) do
      if budget_breach?(e) do
        step_budget_message(subject, "stopped at the #{limits.max_steps}-instruction ceiling")
      else
        Exception.message(e)
      end
    end

    defp classify(e, _limits, _subject), do: Exception.message(e)

    # The rendered message is NOT evidence. Transform sources are untrusted at
    # runtime, and the budget breach is raised as a plain Lua runtime error, so
    #
    #     error("instruction budget exceeded", 0)
    #
    # reproduces the marker byte for byte (level 0 suppresses the `<eval>:1: `
    # position prefix the VM otherwise stamps onto an `error/1` value). Matching
    # the message would let a script forge a resource-limit failure, discard its
    # real diagnostic, and send an operator hunting a runaway loop that never
    # happened — and would equally rewrite a legitimate error that merely quotes
    # the marker.
    #
    # What a script cannot forge is the raise-time instruction tally: reaching the
    # ceiling IS the breach, and `Lua.VM.State.tick!/2` stamps the spent count into
    # the state it ferries out on the error. Both facts are required — a script
    # that genuinely exhausts its budget inside a `pcall` and then raises something
    # else still gets its own message.
    defp budget_breach?(%Lua.RuntimeException{value: @instruction_budget_marker} = e) do
      spent = raise_state(e, :instruction_count)
      ceiling = raise_state(e, :max_instructions)

      is_integer(spent) and is_integer(ceiling) and spent >= ceiling
    end

    defp budget_breach?(_exception), do: false

    # Read the tally defensively. If a future `lua` release moves or renames it,
    # this answers `nil`, no breach is recognised, and the operator gets the VM's
    # own message — the uniform vocabulary is lost, never accuracy. The
    # "script exceeded its step budget" assertion in `lua_sandbox_limits_test.exs`
    # goes red at that point rather than the shim degrading in silence.
    defp raise_state(%Lua.RuntimeException{original: original}, key) when is_struct(original) do
      case Map.get(original, :state) do
        state when is_map(state) -> Map.get(state, key)
        _other -> nil
      end
    end

    defp raise_state(_exception, _key), do: nil
  else
    @doc """
    A fresh sandboxed `t:Lua.t/0`.

    On this backend the CPU ceiling cannot live on the state — `lua 0.4`'s
    `Lua.new/1` takes no limit options at all — so `limits` is carried by
    `eval/4` instead, which *is* the bounded execution call here.
    """
    @spec new_state(Limits.t()) :: Lua.t()
    def new_state(%Limits{}), do: Lua.new()

    @doc """
    Evaluate `source` on `lua`, bounded by `limits`, returning the threaded
    `t:Lua.t/0` so the caller can read globals back out of it.

    `subject` ("script", "signing callback", …) names what ran, for the
    resource-limit messages only.

    On this backend the bounded execution call is `:luerl_sandbox.run/3`, which
    spawns its own runner process carrying the reduction, wall-clock and heap
    ceilings — so this is not `Lua.eval!/2` plus limits, it is the limit
    mechanism itself. Reached through `apply/3` so that a `lua 1.0` install
    (where this branch is not compiled, but the reference would still be
    analysed) emits no undefined-module warning.
    """
    @spec eval(Lua.t(), String.t(), Limits.t(), String.t()) ::
            {:ok, Lua.t()} | {:error, String.t()}
    def eval(%Lua{} = lua, source, %Limits{} = limits, subject \\ "script") do
      case apply(:luerl_sandbox, :run, [source, flags(limits), lua.state]) do
        {:ok, _results, state} -> {:ok, %Lua{lua | state: state}}
        other -> {:error, classify(other, subject)}
      end
    rescue
      e in [Lua.RuntimeException, Lua.CompilerException] ->
        {:error, Exception.message(e)}
    end

    defp flags(%Limits{} = limits) do
      %{
        max_reductions: limits.max_steps,
        # NOT a live wall-clock ceiling: `luerl_sandbox` only reaches its
        # `max_time` receive once the runner has already terminated, whenever
        # `max_reductions` is set — which it always is here. Passed anyway
        # because it costs nothing and would bound the run if the step budget
        # were ever unset. The outer `Task` is the real ceiling; see the
        # "Wall-clock" section of the moduledoc.
        max_time: limits.timeout_ms,
        spawn_opts: [
          {:max_heap_size, %{size: limits.max_memory_words, kill: true, error_logger: false}}
        ]
      }
    end

    defp classify({:lua_error, _reason, _state} = error, _subject),
      do: Exception.message(Lua.RuntimeException.exception(error))

    defp classify({:error, errors, _state}, _subject) when is_list(errors),
      do: Exception.message(Lua.CompilerException.exception(errors))

    defp classify({:error, {:reductions, count}}, subject),
      do: step_budget_message(subject, "killed after #{count} BEAM reductions")

    defp classify({:error, :timeout}, subject),
      do: "#{subject} timed out or exceeded its memory budget"

    # A host API function that raises comes back as the exception struct itself —
    # surface its message, not its guts. Matched on `is_exception/1` rather than
    # the `Lua.*` structs specifically: the built-in `datetime` raises
    # `Lua.RuntimeException` (via `Lua.API.runtime_exception!/1`), but a host
    # module is free to raise anything, and an `inspect`ed `%ArgumentError{}` in
    # `last_error` is exactly the illegibility this clause exists to prevent.
    # (`lua 1.0` wraps such a raise into a `Lua.RuntimeException` itself, so the
    # VM branch needs no counterpart.)
    defp classify({:error, exception}, _subject) when is_exception(exception),
      do: Exception.message(exception)

    defp classify({:error, reason}, subject),
      do: "#{subject} error: #{inspect(reason)}"

    defp classify(other, subject),
      do: "#{subject} error: #{inspect(other)}"
  end

  defp step_budget_message(subject, detail),
    do: "#{subject} #{@step_budget_phrase} (#{detail})"
end
