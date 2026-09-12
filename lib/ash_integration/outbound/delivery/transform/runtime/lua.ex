defmodule AshIntegration.Outbound.Delivery.Transform.Runtime.Lua do
  @max_script_size 10_240
  @default_timeout_ms 5_000
  # The unit is VM instructions, and this default is sized so the step budget is
  # the thing that stops a runaway tight loop — deterministically, with a message
  # naming the budget — rather than the coarser wall-clock backstop.
  #
  # Measured on the `lua 1.0` VM, the cheapest possible loop (`while true do end`)
  # runs ~4.6M instructions/second and an arithmetic one ~3M, so 5M stops them in
  # roughly 1–2s: inside the 5s default `timeout_ms`, with enough margin that the
  # ordering still holds on hardware several times slower. Allocation-heavy loops
  # run far fewer instructions per second (a table-building loop manages ~84k/s),
  # so for those the wall-clock or heap ceiling legitimately fires first — an
  # instruction is not a fixed amount of work, and no single budget can be the
  # first to fire for every shape of script.
  #
  # The headroom over real transforms is enormous: a pass-through costs 1
  # instruction, and building a body from 1000 line items costs ~1000. This is
  # ~5000x the heaviest realistic script.
  #
  # NOTE when re-tuning: before 0.3.0 this counted BEAM reductions on the luerl
  # backend, where 100M was the right order of magnitude. As VM instructions the
  # same number takes 20s+ of CPU, so it could never fire before the wall-clock
  # ceiling and the step budget was effectively inert.
  @default_max_steps 5_000_000
  # Heap+stack ceiling in WORDS (≈8 bytes each on 64-bit, so the default is
  # ~400MB). Exceeding it kills the process holding the heap instantly — an
  # allocation bomb can't OOM the node while waiting for the wall-clock timeout.
  @default_max_heap_words 50_000_000

  # The documented `lua_sandbox` block, rendered from the attributes above so the
  # copy-paste config in the moduledoc cannot drift from the shipped defaults.
  # (It has, twice: the defaults were re-tuned while the docs kept the old
  # numbers, and a host pasting one got a sandbox the docs did not describe.)
  # `guides/delivery-pipeline.md` carries the same block and cannot interpolate,
  # so `lua_sandbox_limits_test.exs` pins it against these same values instead.
  @doc_limits_block [
                      {"timeout_ms", @default_timeout_ms, "wall-clock ceiling per run"},
                      {"max_steps", @default_max_steps,
                       "VM instructions; stops a tight loop in <1s"},
                      {"max_heap_words", @default_max_heap_words,
                       "heap+stack ceiling per run, in words (~400MB)"}
                    ]
                    |> Enum.map(fn {key, value, note} ->
                      grouped =
                        value
                        |> Integer.to_string()
                        |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1_")

                      {"#{key}:", grouped, note}
                    end)
                    |> then(fn rows ->
                      key_width = rows |> Enum.map(&byte_size(elem(&1, 0))) |> Enum.max()
                      val_width = rows |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.max()

                      Enum.map_join(rows, "\n", fn {key, value, note} ->
                        "          #{String.pad_trailing(key, key_width + 1)}" <>
                          "#{String.pad_trailing(value <> ",", val_width + 2)}# #{note}"
                      end)
                    end)

  @moduledoc """
  Sandboxed Lua execution environment for outbound transform scripts.

  This is the `:lua` implementation of the
  `AshIntegration.Outbound.Delivery.Transform.Runtime` behaviour — the in-process
  transform engine. The resolver reaches it through that behaviour (never by
  name), so a future runtime can slot in beside it.

  Execution runs on `lua 1.0`'s own Elixir Lua 5.3 VM, in the calling process.
  Putting a CPU ceiling on an evaluation — configuring it, recognising a breach,
  and reporting one — lives behind
  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Budget`; nothing else
  in this module deals in the VM's own units.

  ## Bounding an untrusted script

  Transform scripts are **operator-authored but untrusted at runtime** (a typo, a
  pathological loop, or hostile event data flowing into the script). Execution is
  bounded so one script can't take down the node:

  - **Function sandboxing** (`Lua.new/1`): `io`, `file`, `os.execute`, `os.exit`,
    `os.getenv`, `package`, `load`, `require`, `dofile`, … all raise if called.
    `Budget.new_state/1` additionally refuses reading an **ambient clock**, which
    `Lua.new/1` leaves reachable: a transform is snapshotted at dispatch and
    replayed on reprocess, and a signing callback re-runs per attempt against a
    frozen `ctx.now`, so a run that reads one silently stops reproducing. The
    line falls between the two forms of the same function, not around it —
    `os.time()`/`os.date()`/`os.clock()` are refused, while `os.time(table)`,
    `os.date(fmt, t)` and `os.difftime(a, b)` are pure functions of their
    arguments and still work. See `Budget`.
  - **Script size**: scripts over #{@max_script_size} bytes are rejected up front.
  - **CPU / steps**: a `max_steps` budget stops a runaway loop. The VM raises the
    breach as a catchable Lua error, so `Budget` also refuses a result from an
    evaluation that spent its whole budget — a script cannot `pcall` its way past
    the ceiling and still deliver. See `Budget`.
  - **Call depth / string size**: recursion deeper than 1000 frames, and any
    single string over a quarter of the heap ceiling, are refused outright rather
    than left to the heap ceiling to catch. See `Budget`.
  - **Memory**: a `:max_heap_size` with `kill: true` on the process holding the
    Lua heap kills an allocation bomb the instant it exceeds the ceiling, before
    it can OOM the node.
  - **Wall-clock**: the outer `Task` bounds total runtime, and is the *only*
    wall-clock enforcement point — the VM has no timer of its own.
  - **Crash isolation**: the script runs under `Task.Supervisor.async_nolink`, so
    a sandbox crash/kill surfaces as an error to the caller instead of taking the
    caller down with it.

  The three resource axes are expressed in the runtime-neutral
  `AshIntegration.Outbound.Delivery.Transform.Limits` vocabulary
  (`max_steps`, `max_memory_words`, `timeout_ms`) and mapped onto the VM's own
  primitives by `Budget`. Limits are configurable (with safe defaults):

      config :ash_integration,
        lua_sandbox: [
  #{@doc_limits_block}
        ]

  `max_steps` counts **VM instructions**, not BEAM reductions — a budget carried
  over from a pre-0.3.0 config is off by more than an order of magnitude in the
  wrong direction and will never fire before `timeout_ms`. See the
  `@default_max_steps` attribute for how the default is sized.

  `:max_reductions` is still read as a deprecated alias for `:max_steps`, but
  **clamped to the default** rather than honoured verbatim: it named the flag
  `lua 0.4`'s luerl backend used, and a value written in BEAM reductions cannot
  be read as VM instructions without disabling the ceiling. A value below the
  default is kept (that intent still means something); one above it is capped.
  `warn_about_sandbox_config/0` says so at boot.

  ## Hitting the ceiling always parks the delivery

  This is a property of *this* sandbox rather than an implementation detail, so
  it belongs here as well as in `Budget`. The VM raises a budget breach as an
  **ordinary Lua error**, which `pcall` catches — so a script could otherwise
  burn its entire budget, swallow the error, and return a half-computed
  descriptor that then gets delivered. `Budget.eval/4` closes that by checking
  the instruction tally on the way out of a *successful* evaluation as well as a
  failed one: a run that reached its ceiling is an error whether or not the
  script noticed. Total CPU was bounded either way (the budget is per top-level
  evaluation and a caught breach is never refunded); what the check preserves is
  that a script which runs out of budget **parks** instead of delivering.

  ## Host APIs

  Sandboxing is subtractive — it takes capabilities away. Some scripts need one
  *back*, in a bounded form: rendering a delivery time in the operator's local
  time needs a time-zone database, which Lua has none of. The alternative is
  worse than a missing feature — it pushes hosts into baking a pre-converted
  timestamp into the canonical event data, where **which** zone to render stops
  being the per-subscription decision it is.

  So the runtime loads **host APIs** — Elixir modules exposed as Lua globals —
  into the state before the author's script runs. `datetime` is built in
  (`AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.DatetimeAPI`):

      datetime.to_zone(iso8601, tz)       -- ISO-8601 carrying that zone's offset
      datetime.format(iso8601, tz, fmt)   -- Calendar.strftime-style formatting

  A host app registers its own (any module that does `use Lua.API`) alongside it:

      config :ash_integration,
        lua_sandbox: [apis: [MyApp.Integration.LuaAPI]]

  Built-ins load first, host modules after, in configured order. **A scope
  collision replaces the earlier module entirely** — `Lua.load_api/2` resets the
  scope table rather than merging into it, so a host module scoped `datetime`
  removes `datetime.to_zone`/`datetime.format` for every script on the node, and
  of two host modules sharing a scope only the last survives. That is
  occasionally what a host wants; far more often it's an accidental name clash,
  so `warn_about_sandbox_config/0` flags both shapes at boot.

  Three properties hold this together:

  - **Host APIs must be pure computation** — no I/O, no network, no filesystem.
    The threat model is "operator-authored but untrusted at runtime", and a
    function that can reach outside the sandbox breaks it for every script on the
    node. Time-zone math qualifies; anything that opens a socket does not. This
    is a contract with the host, not something the runtime can enforce: a
    configured module runs with the full authority of the node.
  - **A host function that burns CPU is inside the budget.** It is invoked by
    the `Task` that is running the Lua code, so its work and its allocations count against
    the same step and heap ceilings as the script's own: calling one in a tight
    loop is bounded exactly like a tight loop of Lua. A host function that
    **blocks** is the awkward case: blocked work executes no VM instructions, so
    nothing counts it against the step budget and only the outer `Task` backstop
    returns. The evaluator *is* that `Task`, so `Task.shutdown(:brutal_kill)`
    does kill it and nothing is leaked — but the step budget is defeated all the
    same, which is the sharpest reason the purity rule above is a rule and not a
    preference.
  - **A script can shadow them, and that hurts only itself.** The APIs are loaded
    before the author's chunk, so `datetime = nil` at the top of a script is
    legal. Every run builds a fresh state and re-loads the APIs into it, so a
    mutated global cannot leak into the next execution — there is no state
    carried between runs to corrupt.

  Signing sources (`sign_session/3`) get the same APIs. That path is narrower —
  callbacks build canonical strings, not delivery bodies — but timestamp
  formatting is exactly what signing schemes need (`%Y%m%dT%H%M%SZ`-style
  canonical stamps), and holding a *pure* utility back from it would only push
  authors into hand-rolled string surgery. The purity bar is what makes the
  surface safe, so it applies identically to both paths.

  The transform is a **function the script exposes**, not a top-level
  imperative chunk:

      function transform(event, defaults)
        defaults.headers["x-thing"] = event.id
        return defaults            -- return nil to skip the event
      end

  The runtime calls `transform(event, defaults)` and uses its **return value**:

  - `event` is the event envelope (a table).
  - `defaults` is the transport-shaped delivery descriptor the caller pre-seeds
    (method/headers/body for HTTP, …); the function may mutate it in place and
    return it, or build and return a fresh table.
  - returning `nil` skips the event.

  A script that defines no `transform` function (including a blank/comment-only
  one) is a **no-op** — the pre-seeded `defaults` are returned unchanged — so the
  common "send the resolved defaults" case needs no function at all. Defining a
  function and **returning** the descriptor is what keeps the contract suitable
  for any runtime, functional ones included (it maps directly onto a WASM guest's
  exported `transform`), rather than baking in Lua's mutate-a-global idiom.
  """

  # Bridge global the wrapper assigns the transform's return value to, then we
  # read back. Underscored to stay out of the author's way.
  @result_global :__transform_result

  # Appended to the author's source: call the exposed `transform` if present,
  # else pass the pre-seeded defaults through unchanged (the no-op case).
  @invoke """

  if type(transform) == "function" then
    #{@result_global} = transform(event, defaults)
  else
    #{@result_global} = defaults
  end
  """

  @behaviour AshIntegration.Outbound.Delivery.Transform.Runtime

  require Logger

  alias AshIntegration.Outbound.Delivery.Transform.Limits
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Budget
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.DatetimeAPI

  # Always loaded, ahead of any host-configured API.
  @builtin_apis [DatetimeAPI]

  @doc """
  Boot check (from `AshIntegration.Supervisor`) for everything in
  `config :ash_integration, lua_sandbox: […]` that is wrong in a way the runtime
  can survive but an operator cannot see:

    * a resource limit that is not a positive integer, which falls back to its
      default rather than crashing a delivery worker;
    * `:max_reductions`, whose unit changed in 0.3.0 and whose value is clamped;
    * an `:apis` entry that isn't a loadable `Lua.API` module, one that claims a
      built-in's scope and so replaces it, or two that claim the same scope as
      each other.

  Each is otherwise invisible until a transform runs — a bad `:apis` entry parks
  every delivery, the scope collisions silently remove functions scripts were
  calling, and a bad limit quietly gives you a sandbox you did not configure.
  This **warns rather than raises**, following
  `AshIntegration.Outbound.PoolCheck`: refusing the host's boot over a
  transform-sandbox setting is a heavier failure than the one it prevents, and a
  node that never runs a transform is unaffected. Every run still validates a
  module before loading it, so a bad entry parks with the same message rather
  than slipping through.
  """
  @spec warn_about_sandbox_config() :: :ok
  def warn_about_sandbox_config do
    warn_about_unusable_limits()
    warn_about_deprecated_step_budget()
    warn_about_host_apis()
  end

  # Every `lua_sandbox` limit that must be a positive integer, with the accessor
  # that reads it, so the check below covers the whole set rather than whichever
  # keys someone remembered.
  @limit_keys [:timeout_ms, :max_steps, :max_reductions, :max_heap_words]

  # A limit configured with something that is not a positive integer is a typo an
  # operator cannot see: `max_steps: "5000000"` (an env var read without
  # `String.to_integer/1`, say) is silently ignored and something else applies, so
  # the sandbox is not the one they configured. `max_steps/0` guards on
  # `is_integer/1` — it has to, since a bad value would otherwise reach
  # `Lua.new/1` — which makes the fallback total and therefore silent. This is
  # what makes it audible.
  defp warn_about_unusable_limits do
    case Enum.filter(@limit_keys, &unusable_limit?/1) do
      [] ->
        :ok

      bad ->
        config = sandbox_config()

        Logger.warning("""
        AshIntegration: these `lua_sandbox` limits are not positive integers and are being
        IGNORED, so the value you configured is not the one in force:
        #{Enum.map_join(bad, ", ", fn key -> "#{inspect(key)}: #{inspect(Keyword.get(config, key))}" end)}.

        #{ignored_limit_effect(bad, config)}

        Every limit is a positive integer — `timeout_ms` in milliseconds, `max_steps` in VM
        instructions, `max_heap_words` in 8-byte BEAM words.
        """)
    end

    :ok
  end

  # What applies in place of an ignored limit. Every key falls back to its own
  # default EXCEPT `:max_steps`, which falls through to `:max_reductions` first —
  # so with `[max_steps: "5000000", max_reductions: 1_000]` the ceiling in force
  # is the clamped alias (1_000), not the default. Naming the default there would
  # send an operator looking for a ceiling that is not the one running.
  defp ignored_limit_effect(bad, config) do
    alias_budget = positive_or_nil(config, :max_reductions)

    if :max_steps in bad and is_integer(alias_budget) do
      "`:max_steps` falls back to the deprecated `:max_reductions` before the default, so the " <>
        "step budget in force is #{deprecated_step_budget(alias_budget)} VM instructions, not " <>
        "the #{@default_max_steps} default. Every other limit above falls back to its default."
    else
      "The default applies instead."
    end
  end

  defp unusable_limit?(key) do
    case Keyword.fetch(sandbox_config(), key) do
      # Absent, or explicitly nil, both mean "not configured".
      :error -> false
      {:ok, nil} -> false
      {:ok, value} -> not (is_integer(value) and value > 0)
    end
  end

  # `:max_reductions` is read in a DIFFERENT UNIT than it was written in, so a
  # host carrying a pre-0.3.0 config forward is silently running a ceiling that
  # means something else. Warned at boot rather than per run: it is a config
  # mistake with a one-line fix, and the runtime would otherwise look fine right
  # up until a runaway reported "timed out" instead of naming the budget.
  # Reads the two keys through `positive_or_nil/2` — the SAME reading `max_steps/0`
  # uses. A warning that disagrees with the code it describes is worse than none:
  # with `[max_steps: 0, max_reductions: 1_000]` a raw `Keyword.get` + `is_integer/1`
  # saw two integers and advised "`:max_steps` wins; drop `:max_reductions`", but
  # `0` is not usable so the ALIAS was the live ceiling — following that advice
  # loosened it from 1_000 to the 5_000_000 default. And `[max_steps: "5000", …]`
  # matched neither clause, so a clamped alias went unmentioned entirely.
  defp warn_about_deprecated_step_budget do
    config = sandbox_config()

    case {positive_or_nil(config, :max_steps), positive_or_nil(config, :max_reductions)} do
      {steps, reductions} when is_integer(steps) and is_integer(reductions) ->
        Logger.warning("""
        AshIntegration: `lua_sandbox` sets BOTH `:max_steps` (#{steps}) and the
        deprecated `:max_reductions` (#{reductions}).

        `:max_steps` wins; drop `:max_reductions`.
        """)

      {nil, reductions} when is_integer(reductions) ->
        warn_deprecated_reductions(reductions)

      _ ->
        :ok
    end

    :ok
  end

  defp warn_deprecated_reductions(reductions) do
    effective = deprecated_step_budget(reductions)

    clamp_note =
      if effective < reductions do
        "That value is being CLAMPED to #{effective}. Read as VM instructions, " <>
          "#{reductions} needs far more CPU than the #{@default_timeout_ms}ms default " <>
          "`timeout_ms` allows, so the step budget could never fire — every runaway would " <>
          "be stopped by the wall-clock backstop instead, reporting \"timed out\" rather " <>
          "than naming the budget."
      else
        "It is at or below the #{@default_max_steps} default, so it is being used as-is — but " <>
          "it was written in a different unit, so confirm it is still the ceiling you want."
      end

    Logger.warning("""
    AshIntegration: `lua_sandbox: [max_reductions: #{reductions}]` is deprecated and its
    UNIT HAS CHANGED.

    Before 0.3.0 it counted BEAM reductions on the luerl backend. The runtime now runs on the
    `lua 1.0` VM and counts VM instructions, which are not comparable.

    #{clamp_note}

    Rename it to `:max_steps` and pick a value in VM instructions. The default is
    #{@default_max_steps}, which stops a tight loop in well under a second and is still
    ~5000x the heaviest realistic transform.
    """)
  end

  # The `:apis` half of the boot check. Private: `warn_about_sandbox_config/0` is
  # the single entry point the supervisor calls.
  defp warn_about_host_apis do
    configured = configured_apis()
    {loadable, unloadable} = Enum.split_with(configured, &lua_api_module?/1)

    warn_unloadable(unloadable)
    warn_shadowed_builtins(Enum.flat_map(loadable, &shadowed_builtin/1))
    warn_shadowed_hosts(shadowed_hosts(loadable))

    :ok
  end

  defp warn_unloadable([]), do: :ok

  defp warn_unloadable(modules) do
    Logger.warning("""
    AshIntegration: these `config :ash_integration, lua_sandbox: [apis: [...]]` entries \
    are not Lua API modules: #{Enum.map_join(modules, ", ", &inspect/1)}.

    Every entry must be a module that does `use Lua.API`. As configured, EVERY transform
    and custom signing run on this node will park with a load error — the APIs load into
    the sandbox before the author's script does, so even a script that calls none of them
    fails.
    """)
  end

  defp warn_shadowed_builtins([]), do: :ok

  defp warn_shadowed_builtins(collisions) do
    for {module, builtin, scope} <- collisions do
      Logger.warning("""
      AshIntegration: #{inspect(module)} claims the Lua scope #{inspect(scope)}, which \
      REPLACES the built-in #{inspect(builtin)} entirely.

      `Lua.load_api/2` overwrites the scope table rather than merging into it, so these \
      built-in functions are gone for every transform and signing run on this node: \
      #{scoped_names(builtin, scope)}. A script still calling one fails with an \
      undefined-function error.

      Rename your scope unless replacing the built-in outright is what you intended.
      """)
    end

    :ok
  end

  defp warn_shadowed_hosts([]), do: :ok

  defp warn_shadowed_hosts(collisions) do
    for {winner, shadowed, scope} <- collisions do
      Logger.warning("""
      AshIntegration: these `config :ash_integration, lua_sandbox: [apis: [...]]` entries \
      all claim the Lua scope #{inspect(scope)}: \
      #{Enum.map_join(shadowed ++ [winner], ", ", &inspect/1)}.

      `Lua.load_api/2` overwrites the scope table rather than merging into it, so the LAST \
      entry wins — #{inspect(winner)} — and the earlier ones are replaced wholesale for \
      every transform and signing run on this node. #{lost_sentence(shadowed, winner, scope)}

      Give each module its own scope unless replacing the others outright is what you intended.
      """)
    end

    :ok
  end

  # Two host modules claiming one scope is the same wholesale replacement as a
  # built-in collision, minus the built-in — and likelier, since the host picks
  # both names. `:apis` order decides it: the last entry loaded wins.
  defp shadowed_hosts(loadable) do
    loadable
    |> Enum.uniq()
    |> Enum.group_by(& &1.scope())
    |> Enum.filter(fn {_scope, modules} -> length(modules) > 1 end)
    |> Enum.map(fn {scope, modules} ->
      {List.last(modules), Enum.drop(modules, -1), Enum.join(scope, ".")}
    end)
  end

  # Only the names the winner does NOT redefine actually disappear; the rest are
  # still callable, just backed by a different module. Say which happened.
  defp lost_sentence(shadowed, winner, scope) do
    kept = MapSet.new(function_names(winner))

    lost =
      shadowed
      |> Enum.flat_map(&function_names/1)
      |> Enum.reject(&MapSet.member?(kept, &1))
      |> Enum.uniq()

    case lost do
      [] ->
        "No functions disappear — #{inspect(winner)} defines the same names — but its " <>
          "implementations replace theirs."

      names ->
        "These functions are gone, and a script still calling one fails with an " <>
          "undefined-function error: " <> Enum.map_join(names, ", ", &"#{scope}.#{&1}") <> "."
    end
  end

  # `[{name, with_state?, variadic?}, …]` — what `use Lua.API` records for a module.
  defp function_names(module) do
    Enum.map(module.__lua_functions__(), fn {name, _state?, _variadic?} -> name end)
  end

  defp scoped_names(builtin, scope) do
    Enum.map_join(function_names(builtin), ", ", &"#{scope}.#{&1}")
  end

  defp shadowed_builtin(module) do
    scope = module.scope()

    case Enum.find(@builtin_apis, &(&1.scope() == scope)) do
      # A host listing a built-in explicitly just loads it twice — harmless.
      nil -> []
      ^module -> []
      builtin -> [{module, builtin, Enum.join(scope, ".")}]
    end
  end

  @doc """
  Convenience entry point: run `script` against `event_data` using the
  config-driven default limits. `opts` may carry `:defaults` — the pre-seeded
  descriptor passed to `transform/2`. Prefer
  `AshIntegration.Outbound.Delivery.Transform.Runtime` for dispatch; this arity
  keeps the direct, limit-free call ergonomic.
  """
  def execute(script, event_data, opts \\ []) when is_list(opts) do
    execute(script, event_data, Keyword.get(opts, :defaults), default_limits())
  end

  @impl true
  def default_limits do
    %Limits{
      timeout_ms: timeout_ms(),
      max_steps: max_steps(),
      max_memory_words: max_heap_words()
    }
  end

  @impl true
  def validate(script) when byte_size(script) > @max_script_size do
    {:error, "script exceeds maximum size of #{@max_script_size} bytes"}
  end

  # Parse (compile) the chunk WITHOUT running it. This is the early check we can
  # make with certainty: it catches syntax errors at save time, with no false
  # negatives. A script that parses can still fail at runtime on real event data
  # — by design that parks the delivery for reprocessing rather than being
  # rejected here — so this deliberately stops at "does it parse".
  def validate(script) do
    case Lua.parse_chunk(script) do
      {:ok, _chunk} -> :ok
      {:error, errors} -> {:error, "script does not parse: #{format_errors(errors)}"}
    end
  end

  # `parse_chunk/1` answers `{:error, %Lua.CompilerException{}}`. The list clause
  # below is kept as a fallback for a future release that reports raw strings
  # again: `to_string/1` on an exception struct RAISES, so a single clause of
  # either shape would crash on the other.
  defp format_errors(error) when is_exception(error), do: Exception.message(error)

  defp format_errors(errors), do: errors |> List.wrap() |> Enum.map_join("; ", &to_string/1)

  @impl true
  def execute(script, _event, _defaults, _limits) when byte_size(script) > @max_script_size do
    {:error, "script exceeds maximum size of #{@max_script_size} bytes"}
  end

  def execute(script, event, defaults, %Limits{} = limits) do
    task =
      Task.Supervisor.async_nolink(AshIntegration.TaskSupervisor, fn ->
        # THE memory ceiling: the VM evaluates in this very process, so this flag
        # bounds the Lua heap itself — and, just as importantly, the reading and
        # decoding of the `result` table (read_result/decode_result), which also
        # runs here and could otherwise balloon the heap on a
        # within-budget-but-huge result. (kill: true → surfaces as `{:exit, _}`.)
        Process.flag(:max_heap_size, %{
          size: limits.max_memory_words,
          kill: true,
          error_logger: false
        })

        run_sandboxed(script, event, defaults, limits)
      end)

    # THE wall-clock ceiling — not a backstop behind an inner one. The VM has no
    # timer of its own, so there is no inner deadline to leave grace for and the
    # timeout an operator is told about is the one actually applied.
    # Because the task is `async_nolink`, a brutal-kill or crash here comes back
    # as `{:exit, _}` — never propagated to (and crashing) the caller.
    case Task.yield(task, limits.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, "transform sandbox crashed or was killed"}
      nil -> {:error, "script execution timed out after #{limits.timeout_ms}ms"}
    end
  end

  @impl true
  def sign_session(source, %Limits{} = _limits, _orchestrate)
      when byte_size(source) > @max_script_size do
    {:error, "script exceeds maximum size of #{@max_script_size} bytes"}
  end

  def sign_session(source, %Limits{} = limits, orchestrate) when is_function(orchestrate, 1) do
    task =
      Task.Supervisor.async_nolink(AshIntegration.TaskSupervisor, fn ->
        Process.flag(:max_heap_size, %{
          size: limits.max_memory_words,
          kill: true,
          error_logger: false
        })

        run_session(source, limits, orchestrate)
      end)

    # ONE wall-clock ceiling for the whole signing pipeline (all callbacks share
    # it), so a pathological source can't multiply latency by the number of
    # callbacks the way per-call Tasks would.
    case Task.yield(task, limits.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, "signing sandbox crashed or was killed"}
      nil -> {:error, "signing callbacks timed out after #{limits.timeout_ms}ms"}
    end
  end

  # The signing callbacks the runtime knows about, in no particular order.
  @signing_callbacks ~w(content string_to_sign headers body url)

  # Appended to the author's source: record which signing callbacks are functions
  # so the orchestrator can skip the undefined ones with no further sandbox run.
  @detect_callbacks "\n__sign_defined = {" <>
                      Enum.map_join(@signing_callbacks, ", ", fn name ->
                        "#{name} = type(#{name}) == \"function\""
                      end) <> "}\n"

  # Compile the author source ONCE (defining its signing callbacks) and detect
  # which are present in the same run; then hand the orchestrator a `call/2` that
  # invokes a single callback on that ALREADY-COMPILED state — no source re-parse,
  # all under the one Task + one budget above. The orchestrator (the caller's
  # Elixir pipeline) performs the keyed MAC between calls; the secret is never set
  # into the sandbox state.
  defp run_session(source, %Limits{} = limits, orchestrate) do
    with {:ok, lua} <- new_state(limits) do
      compile_session(source, lua, limits, orchestrate)
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end

  defp compile_session(source, lua, %Limits{} = limits, orchestrate) do
    case Budget.eval(lua, source <> @detect_callbacks, limits, "signing source") do
      {:ok, lua} ->
        defined = read_defined(lua)
        orchestrate.(fn fname, ctx -> sign_call_on(lua, limits, defined, fname, ctx) end)

      {:error, message} ->
        {:error, message}
    end
  end

  # Invoke one already-compiled callback on the shared state. An undefined callback
  # short-circuits to `:undefined` with no sandbox run at all. `lua` is the state
  # as of compilation, so each callback starts from the same point and a mutation
  # one callback makes cannot leak into the next.
  defp sign_call_on(lua, %Limits{} = limits, defined, fname, ctx) do
    if MapSet.member?(defined, fname) do
      lua = set_global(lua, :__ctx, ctx)

      case Budget.eval(lua, "__sign_result = #{fname}(__ctx)", limits, "signing callback") do
        {:ok, lua} -> {:ok, {:defined, decode_result(Lua.get!(lua, [:__sign_result]))}}
        {:error, message} -> {:error, message}
      end
    else
      {:ok, :undefined}
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end

  defp read_defined(lua) do
    case Lua.get!(lua, [:__sign_defined]) do
      table when is_list(table) ->
        for {k, true} <- table, into: MapSet.new(), do: to_string(k)

      _ ->
        MapSet.new()
    end
  end

  # Runs inside the async_nolink task. This function only builds the pre-seeded
  # state and reads the outcome back; `Budget.eval/4` is the bounded execution
  # call and classifies every failure into one message vocabulary.
  defp run_sandboxed(script, event, defaults, %Limits{} = limits) do
    with {:ok, lua} <- new_state(limits) do
      lua =
        lua
        |> set_global(:event, event)
        |> maybe_set_global(:defaults, defaults)

      # The author's source defines `transform`; @invoke calls it (or passes the
      # defaults through, for a no-op script) and stashes the RETURN value in the
      # bridge global we read back. Both run under the one bounded sandbox call.
      case Budget.eval(lua, script <> @invoke, limits, "script") do
        {:ok, lua} -> read_result(lua)
        {:error, message} -> {:error, message}
      end
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end

  # The transform's return value (`nil` → skip the event).
  defp read_result(lua) do
    case Lua.get!(lua, [@result_global]) do
      nil -> {:ok, :skip}
      result -> {:ok, decode_result(result)}
    end
  end

  # A FRESH sandbox state per run, with the built-in and host-configured APIs
  # loaded into it. Nothing is carried over between runs, so a script that
  # shadows or clobbers an API global affects only its own execution. `limits`
  # reaches `Budget.new_state/1` because the CPU, call-depth and string-size
  # ceilings are options ON the state.
  #
  # Built in two steps with a rescue each, because BOTH steps raise
  # `ArgumentError` and they mean opposite things: `Lua.new/1` rejects an
  # out-of-range ceiling (`max_steps: 0`), while `load_host_api/2` rejects a
  # non-`Lua.API` module. Building the state inside the same `try` as the reduce
  # would let a bad *limit* be reported as a bad `:apis` config, sending an
  # operator to the wrong setting entirely.
  defp new_state(%Limits{} = limits) do
    with {:ok, lua} <- build_state(limits) do
      load_host_apis(lua)
    end
  end

  defp build_state(%Limits{} = limits) do
    {:ok, Budget.new_state(limits)}
  rescue
    # `Lua.new/1` validates the ceilings `Budget` derives from `Limits`, so this
    # is a bad limit — name that, not the APIs. Config cannot reach here (every
    # `lua_sandbox` limit falls back to its default when it is not a positive
    # integer), so in practice this is a caller passing explicit `%Limits{}`.
    e in ArgumentError ->
      {:error, "invalid transform sandbox limits: #{Exception.message(e)}"}

    e ->
      {:error, "could not build the transform sandbox: #{Exception.message(e)}"}
  end

  defp load_host_apis(lua) do
    {:ok, Enum.reduce(host_apis(), lua, &load_host_api/2)}
  rescue
    # The only thing `load_host_api/2` itself raises — attribute it precisely.
    e in ArgumentError ->
      {:error, "could not load the configured Lua host APIs: #{Exception.message(e)}"}

    # Anything else (a module's `install/3`) is a different failure and shouldn't
    # be reported as a bad `:apis` config.
    e ->
      {:error, "could not build the transform sandbox: #{Exception.message(e)}"}
  end

  # Gate on `__lua_functions__/0` — the function `Lua.load_api/2` actually needs,
  # and one only `use Lua.API` generates. Probing `scope/0` instead would wave
  # through a module that happens to export it for unrelated reasons, which then
  # dies inside `load_api` with a raw UndefinedFunctionError — exactly the
  # near-miss this message exists to explain.
  defp load_host_api(module, lua) do
    if lua_api_module?(module) do
      Lua.load_api(lua, module)
    else
      raise ArgumentError,
            "#{inspect(module)} is not a Lua API module — every entry in " <>
              "`config :ash_integration, lua_sandbox: [apis: [...]]` must `use Lua.API`"
    end
  end

  defp lua_api_module?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :__lua_functions__, 0)
  end

  defp set_global(lua, key, data) do
    {encoded, lua} = Lua.encode!(lua, stringify_keys(data))
    Lua.set!(lua, [key], encoded)
  end

  defp maybe_set_global(lua, _key, nil), do: lua
  defp maybe_set_global(lua, key, data), do: set_global(lua, key, data)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp decode_result(table) when is_list(table) do
    cond do
      table == [] ->
        []

      keyword_table?(table) ->
        Map.new(table, fn {k, v} -> {k, decode_result(v)} end)

      sequence_table?(table) ->
        table |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&decode_result(elem(&1, 1)))

      true ->
        Enum.map(table, &decode_result/1)
    end
  end

  defp decode_result(value), do: value

  defp keyword_table?([{k, _v} | _]) when is_binary(k), do: true
  defp keyword_table?(_), do: false

  # Lua returns a sequence (array) table as an integer-keyed proplist
  # (`[{1, v1}, {2, v2}, ...]`). Decode it to an ordered list of decoded values.
  defp sequence_table?([{k, _v} | _]) when is_integer(k), do: true
  defp sequence_table?(_), do: false

  # ── Config ──────────────────────────────────────────────────────────────

  defp sandbox_config,
    do: Keyword.get(Application.get_all_env(:ash_integration), :lua_sandbox, [])

  # The built-ins always load; host-configured APIs load after them. A host scope
  # that collides with a built-in's therefore REPLACES it wholesale (`Lua.load_api/2`
  # resets the scope table rather than merging), which `warn_about_sandbox_config/0`
  # surfaces at boot because the far likelier cause is an accidental name clash.
  defp host_apis, do: @builtin_apis ++ configured_apis()

  defp configured_apis, do: List.wrap(Keyword.get(sandbox_config(), :apis, []))

  defp timeout_ms, do: positive_integer(:timeout_ms, @default_timeout_ms)

  # `:max_reductions` named the flag `lua 0.4`'s luerl backend used, which this
  # runtime no longer runs on. `:max_steps` (the `Limits` vocabulary) is the name
  # to use.
  #
  # The old key is still read, but it is CLAMPED to the default rather than
  # honoured verbatim, because the unit changed underneath it. `:max_steps` is
  # new in 0.3.0, so every host upgrading from an earlier release wrote
  # `:max_reductions`, and wrote it in BEAM reductions. Read as VM instructions
  # those numbers are wrong by more than an order of magnitude in the direction
  # that disables the ceiling: a carried-over `max_reductions: 100_000_000` needs
  # 20s+ of CPU, so it can never fire before `timeout_ms` and every runaway is
  # stopped by the wall-clock backstop instead — the exact inert-budget defect
  # 0.3.0 fixed for the default, reintroduced for the only population this alias
  # exists to serve.
  #
  # `min/2` is the honest reading of intent across that unit change:
  #
  #   * A value BELOW the default was someone asking for a stricter ceiling than
  #     stock. That intent still means something, so it is kept.
  #   * A value ABOVE it cannot mean "looser than stock" in the new unit, because
  #     in the new unit it means "no ceiling at all". It is capped at the default,
  #     which is itself ~5000x the heaviest realistic transform.
  #
  # Either way `warn_about_sandbox_config/0` tells the operator at boot, so the
  # clamp is visible rather than a silent second surprise.
  defp max_steps do
    config = sandbox_config()

    case {positive_or_nil(config, :max_steps), positive_or_nil(config, :max_reductions)} do
      {steps, _} when is_integer(steps) -> steps
      {_, reductions} when is_integer(reductions) -> min(reductions, @default_max_steps)
      _ -> @default_max_steps
    end
  end

  # The configured value if it is a positive integer, else `nil` so the caller
  # falls through. Every limit treats a bad value the same way — fall back to the
  # default and say so at boot — rather than each key failing in its own place
  # and its own way.
  defp positive_or_nil(config, key) do
    case Keyword.get(config, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  @doc false
  # The clamp above, exposed so the boot warning and its test read the same rule
  # rather than restating it.
  @spec deprecated_step_budget(integer()) :: integer()
  def deprecated_step_budget(reductions), do: min(reductions, @default_max_steps)

  defp max_heap_words, do: positive_integer(:max_heap_words, @default_max_heap_words)

  # A configured limit, or `default` if it is anything other than a positive
  # integer — `nil` included, since `Keyword.get/3` returns a stored `nil` rather
  # than the default.
  #
  # This is a SAFETY fallback, not tidiness. These values are not merely read;
  # they are handed to `Process.flag(:max_heap_size, %{size: …})` and
  # `Task.yield(task, …)`, neither of which tolerates a non-integer. A bad
  # `:timeout_ms` used to raise `FunctionClauseError` inside `Task.yield/2` —
  # in the CALLER, taking down the delivery worker rather than parking the
  # delivery — and a bad `:max_heap_words` killed the sandbox `Task`, which the
  # caller then reported as "sandbox crashed or was killed", pointing at the
  # script instead of the config. A typo in a ceiling must not be able to do
  # either. `warn_about_sandbox_config/0` names the offending key at boot so the
  # fallback is not silent.
  defp positive_integer(key, default),
    do: positive_or_nil(sandbox_config(), key) || default
end
