defmodule AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Budget do
  # Deep enough for any plausible transform (real Lua errors at ~200 nested C
  # calls), shallow enough that runaway recursion is refused outright. A constant
  # rather than a `Limits` field: `Limits` is the runtime-neutral vocabulary, and
  # call depth has no counterpart in (say) a WASM guest's fuel/memory model.
  @max_call_depth 1_000

  # Clock paths `Lua.new/1` leaves reachable. These are always ambient — no
  # argument form makes them reproducible — so they are refused outright.
  @ambient_clocks [
    [:os, :clock],
    # Non-standard `lua 1.0` extensions, easy to miss when auditing against a
    # stock 5.3 surface.
    [:os, :time_ms],
    [:os, :time_us]
  ]

  # Ambient unless handed a usable instant. The requirement is derived from what
  # the VM itself falls back on, NOT from argument count — counting arguments is
  # the bug this replaced, since `os.time(nil)` and `os.date(fmt, nil)` carry an
  # argument and still read the clock:
  #
  #   * `os_time/2` uses its first argument only when it is a table ref; `[]` and
  #     `[nil | _]` both return `System.os_time/1`.
  #   * `os_date/2` uses its SECOND argument only `when is_number(t)`; anything
  #     else — absent, nil, a string, a boolean — falls through to
  #     `System.os_time/1`.
  #
  # `{path, requirement}`, checked by `instant_given?/2`.
  @guarded_clocks [
    {[:os, :time], :table_at_0},
    {[:os, :date], :number_at_1}
  ]

  @moduledoc """
  The sandbox ceilings for one evaluation: where they are configured, and how a
  breach is recognised and reported.

  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua` speaks the
  runtime-neutral `AshIntegration.Outbound.Delivery.Transform.Limits` vocabulary
  (`max_steps`, `max_memory_words`, `timeout_ms`); this module is the only place
  that maps it onto the `lua` package's own primitives. Wall-clock and memory are
  the *caller's* to enforce — see `Runtime.Lua`.

  ## The ceilings live on the state

  The work budget is `:max_instructions`, an option on `Lua.new/1` counted in VM
  instructions, per top-level evaluation and reset at each one. Two more are
  tightened rather than left at their defaults (`:infinity` and 256 MiB):

    * `:max_call_depth` — a fixed #{@max_call_depth} frames.
    * `:max_string_bytes` — a quarter of `:max_memory_words` (as bytes). The
      default permits a single string large enough to trip a smaller heap ceiling
      *mid-allocation*, where the kill depends on GC timing; sizing it under the
      heap cap makes the single-string bomb a deterministic refusal instead.

  ## A breach parks the delivery, even when the script catches it

  The VM raises the breach as an ordinary Lua error, so `pcall` catches it. Left
  alone a script could burn its whole budget, swallow the error, and return a
  normal descriptor — which would then be delivered. Total CPU is bounded either
  way (`State.unwind_to/2` carries the tally across a protected call as a
  monotonic max, so a caught breach is never refunded), but the invariant that
  matters is stronger: reaching the ceiling parks.

  So `eval/4` checks the tally leaving a *successful* evaluation too. `tick!/2`
  raises **at** the ceiling and `Lua.VM.execute/3` stamps the tally back into
  `state.instruction_count`, so a run that never breached is always strictly
  under its ceiling and one that did reports exactly it — exact in both
  directions, with no false positive for an expensive-but-honest script.

  The rendered message is **not** evidence: `error("instruction budget exceeded", 0)`
  reproduces the VM's marker byte for byte, so matching on it would let a script
  fabricate a resource-limit failure and bury its real diagnostic. The raise-time
  tally cannot be forged, so `budget_breach?/1` requires both.

  ## No ambient clock

  `Lua.new/1` sandboxes `io`, `file`, `package`, `load`, `require` and the
  process-reaching parts of `os`, but leaves the clock readable. `new_state/1`
  closes that — refusing to **read** a clock, not time handling as such, with the
  line falling between the two forms of the same function.

  The test is on the argument's **value**, in the position the VM consults, not
  on how many arguments were passed: `os.time(nil)` and `os.date(fmt, nil)` each
  carry an argument and still read the clock, as does `os.date(fmt, "x")`.

  | Call | | Why |
  | --- | --- | --- |
  | `os.time()`, `os.time(nil)`, `os.time(<non-table>)` | refused | reads the clock |
  | `os.time({year = 2024, …})` | **allowed** | converts a table it was handed |
  | `os.date()`, `os.date(fmt)`, `os.date(fmt, nil)`, `os.date(fmt, "x")` | refused | formats *now* |
  | `os.date(fmt, 1718447400)` | **allowed** | formats the instant it was handed |
  | `os.clock()`, `os.time_ms()`, `os.time_us()` | refused | no argument form exists |
  | `os.difftime(a, b)` | **allowed** | arithmetic over both arguments |

  Both callers depend on a run reproducing: a transform is snapshotted at dispatch
  and replayed on reprocess, and a signing callback re-runs per attempt against a
  frozen `ctx.now` — there, reading a clock means a valid signature over the wrong
  string, the silent 401 `design/configurable-signing.md` exists to prevent.
  Refusing the argument forms too would be over-blocking with nowhere to go:
  `DatetimeAPI` requires an ISO-8601 string with an offset, so a transform
  rendering a Unix timestamp out of `event.data` has no other route.

  > Not covered: `math.random` is also non-deterministic. It is left available —
  > legitimate uses, no documented promise — but a signing callback must not use
  > it, for the same reason.
  """

  alias AshIntegration.Outbound.Delivery.Transform.Limits

  # Necessary but never sufficient to recognise a breach — see the moduledoc.
  @instruction_budget_marker "instruction budget exceeded"

  # `Limits` vocabulary, with the VM's own unit in the parenthetical so an
  # operator reading `last_error` can tell what actually stopped the script.
  @step_budget_phrase "exceeded its step budget"

  @doc """
  A fresh sandboxed `t:Lua.t/0` carrying the CPU, call-depth and string-size
  ceilings, with the ambient clock closed off. See the moduledoc.

  Raises `ArgumentError` if `limits` carries a ceiling `Lua.new/1` rejects (a
  non-positive `max_steps`, say); the caller turns that into a message naming the
  offending *setting*.
  """
  @spec new_state(Limits.t()) :: Lua.t()
  def new_state(%Limits{} = limits) do
    lua =
      Lua.new(
        max_instructions: limits.max_steps,
        max_call_depth: @max_call_depth,
        max_string_bytes: max_string_bytes(limits)
      )

    lua
    |> then(&Enum.reduce(@ambient_clocks, &1, fn path, acc -> Lua.sandbox(acc, path) end))
    |> then(
      &Enum.reduce(@guarded_clocks, &1, fn {path, requirement}, acc ->
        guard_clock(acc, path, requirement)
      end)
    )
  end

  # The original is captured BEFORE the override and closed over, so the wrapper
  # delegates rather than reimplementing Lua's `os.date`/`os.time` semantics as a
  # second, silently diverging strftime.
  #
  # `{:native_func, _}` is a documented `lua` VM internal that may change, so an
  # unrecognised shape falls back to sandboxing the path outright — the safe
  # direction, and one the argument-form tests catch rather than degrading
  # silently into an unguarded clock.
  defp guard_clock(%Lua{} = lua, path, requirement) do
    case Lua.get!(lua, path, decode: false) do
      {:native_func, original} -> Lua.set!(lua, path, guarded(original, path, requirement))
      _unrecognised -> Lua.sandbox(lua, path)
    end
  end

  defp guarded(original, path, requirement) do
    fn args, %Lua{} = lua ->
      if instant_given?(requirement, args) do
        {results, state} = original.(args, lua.state)
        {results, %{lua | state: state}}
      else
        raise Lua.RuntimeException, ambient_message(path, requirement)
      end
    end
  end

  # Does this call carry the instant, in the position and shape the VM actually
  # consults? Anything else — a missing argument, `nil`, a string, a boolean —
  # makes the underlying function read the clock, so it is refused.
  #
  # `{:tref, _}` is a `lua` VM internal, like `{:native_func, _}` above. If it
  # ever changes shape this answers `false` and `os.time(table)` is refused
  # rather than silently reading the clock — the safe direction, and one the
  # allowed-form tests turn red on rather than letting it degrade quietly.
  defp instant_given?(:table_at_0, args), do: match?({:tref, _}, Enum.at(args, 0))
  defp instant_given?(:number_at_1, args), do: is_number(Enum.at(args, 1))

  defp ambient_message(path, requirement) do
    call = Enum.map_join(path, ".", &Atom.to_string/1)

    "#{call} would read the clock here and is sandboxed — a transform is replayed " <>
      "on reprocess and a signing callback re-runs per attempt, so a run that reads " <>
      "an ambient clock stops reproducing. #{instant_hint(requirement)} " <>
      "The instant can come from `ctx.now` or a field on the event; the `datetime` " <>
      "host API takes one too."
  end

  # Name the shape that is missing, not just the rule: the argument may be
  # present but `nil` or the wrong type, which is exactly the case an author
  # cannot see from "is sandboxed".
  defp instant_hint(:table_at_0),
    do: "Pass a date table, as in `os.time({year = 2024, month = 6, day = 15})`."

  defp instant_hint(:number_at_1),
    do: "Pass a numeric timestamp as the second argument, as in `os.date(fmt, 1718447400)`."

  @doc """
  Every clock path `new_state/1` guards, as `{path, requirement}` — `requirement`
  being what the call must carry to be reproducible, or `:never` for the paths
  that have no such form. Exposed so tests assert on the real list rather than a
  restated copy that silently stops covering a path added here.
  """
  @spec clock_paths() :: [{[atom()], :never | :table_at_0 | :number_at_1}]
  def clock_paths do
    Enum.map(@ambient_clocks, &{&1, :never}) ++ @guarded_clocks
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

  `new_state/1` baked the CPU ceiling into the state, so this is `Lua.eval!/2`
  with its exceptions classified, plus the exhaustion check that keeps a
  `pcall`-swallowed breach from returning a result. See the moduledoc.
  """
  @spec eval(Lua.t(), String.t(), Limits.t(), String.t()) ::
          {:ok, Lua.t()} | {:error, String.t()}
  def eval(%Lua{} = lua, source, %Limits{} = limits, subject \\ "script") do
    {_results, lua} = Lua.eval!(lua, source)

    case lua |> tally() |> budget_outcome() do
      :within ->
        {:ok, lua}

      :exhausted ->
        {:error,
         step_budget_message(
           subject,
           "spent all #{limits.max_steps} instructions; the breach was caught inside " <>
             "the #{subject} (pcall), so its result is discarded"
         )}

      :unverifiable ->
        {:error,
         "#{subject} was refused: AshIntegration could not read the Lua VM's instruction " <>
           "tally, so it cannot confirm the step budget was not exhausted and swallowed by " <>
           "a pcall. This build of the `lua` package is not supported — pin a version whose " <>
           "`Lua.VM.State` still carries `:instruction_count` and `:max_instructions`."}
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, classify(e, limits, subject)}
  end

  @doc false
  # What a post-evaluation tally means. Separated from `eval/4` so the decision —
  # in particular the `:unverifiable` case, which cannot be produced through the
  # real VM — is directly testable.
  #
  # `:exhausted` means the run reached its ceiling and still returned, which can
  # only happen if the breach was raised and caught inside Lua. It cannot fire on
  # a merely expensive script: see the moduledoc on why the test is exact.
  #
  # `:unverifiable` FAILS CLOSED, unlike `budget_breach?/1` below. The asymmetry
  # is deliberate and is about what is at stake in each direction:
  #
  #   * `budget_breach?/1` classifies a run that ALREADY failed. An unreadable
  #     tally there costs only the uniform message — the operator still gets the
  #     VM's own error, and nothing is delivered.
  #   * Here the run SUCCEEDED and we are deciding whether to ship its result.
  #     Answering "not exhausted" because we cannot tell silently reopens the
  #     pcall-swallow hole this module exists to close. `mix.exs` accepts
  #     `~> 1.0` and nothing pins the counters, so a 1.x release that renames
  #     them is an ordinary dependency bump.
  @spec budget_outcome({non_neg_integer(), non_neg_integer()} | :unknown) ::
          :within | :exhausted | :unverifiable
  def budget_outcome(:unknown), do: :unverifiable
  def budget_outcome({spent, ceiling}) when spent >= ceiling, do: :exhausted
  def budget_outcome({_spent, _ceiling}), do: :within

  defp classify(%Lua.RuntimeException{} = e, %Limits{} = limits, subject) do
    if budget_breach?(e) do
      step_budget_message(subject, "stopped at the #{limits.max_steps}-instruction ceiling")
    else
      Exception.message(e)
    end
  end

  defp classify(e, _limits, _subject), do: Exception.message(e)

  # Both halves required: the marker AND a raise-time tally that reached the
  # ceiling. Either alone is forgeable or wrong. Unlike `budget_outcome/1` this
  # may fail open: the run already failed, so an unreadable tally costs the
  # uniform message and nothing else — the VM's own error still reaches the
  # operator, and no result is delivered either way.
  defp budget_breach?(%Lua.RuntimeException{value: @instruction_budget_marker} = e) do
    case e.original |> raise_state() |> tally() do
      {spent, ceiling} -> spent >= ceiling
      :unknown -> false
    end
  end

  defp budget_breach?(_exception), do: false

  # Read defensively; `:unknown` when the counters are not where this expects.
  # What that then means differs by caller — see `budget_outcome/1`.
  defp tally(%Lua{state: state}), do: tally(state)

  defp tally(%{instruction_count: spent, max_instructions: ceiling})
       when is_integer(spent) and is_integer(ceiling),
       do: {spent, ceiling}

  defp tally(_other), do: :unknown

  defp raise_state(original) when is_struct(original), do: Map.get(original, :state)
  defp raise_state(_other), do: nil

  defp step_budget_message(subject, detail),
    do: "#{subject} #{@step_budget_phrase} (#{detail})"
end
