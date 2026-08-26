defmodule AshIntegration.Outbound.Delivery.Transform.Runtime.Lua do
  @max_script_size 10_240
  @default_timeout_ms 5_000
  # ~100M steps ≈ a fraction of a second of runaway CPU before the script is
  # stopped. The unit is the backend's (BEAM reductions on `:luerl`, VM
  # instructions on `:lua_vm`) and neither is a wall-clock measure, so the outer
  # wall-clock backstop catches anything that slips past either way.
  @default_max_steps 100_000_000
  # Heap+stack ceiling in WORDS (≈8 bytes each on 64-bit, so the default is
  # ~400MB). Exceeding it kills the process holding the heap instantly — an
  # allocation bomb can't OOM the node while waiting for the wall-clock timeout.
  @default_max_heap_words 50_000_000

  @moduledoc """
  Sandboxed Lua execution environment for outbound transform scripts.

  This is the `:lua` implementation of the
  `AshIntegration.Outbound.Delivery.Transform.Runtime` behaviour — the in-process
  transform engine. The resolver reaches it through that behaviour (never by
  name), so a future runtime can slot in beside it.

  Everything here runs on the **stable `Lua` API** — the surface `lua 0.4.x` and
  `lua 1.0.x` spell identically. The single genuinely version-specific concern,
  putting a CPU ceiling on an evaluation, lives behind
  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat`, which also
  decides which backend this node compiled against:

  - **`:luerl`** (`lua 0.4`) — the Lua code runs in a luerl-spawned runner process.
  - **`:lua_vm`** (`lua 1.0`) — `lua`'s own Elixir Lua 5.3 VM, evaluating
    in-process. `lua 1.0` dropped luerl as a dependency entirely.

  Nothing else in this module knows which one it is.

  ## Bounding an untrusted script

  Transform scripts are **operator-authored but untrusted at runtime** (a typo, a
  pathological loop, or hostile event data flowing into the script). Execution is
  bounded so one script can't take down the node:

  - **Function sandboxing** (`Lua.new/1`): `io`, `os.execute`, `os.exit`,
    `os.getenv`, `package`, `load`, `require`, `dofile`, … all raise if called.
  - **Script size**: scripts over #{@max_script_size} bytes are rejected up front.
  - **CPU / steps**: a `max_steps` budget stops a runaway loop — by killing the
    luerl runner on `:luerl`, by raising a Lua error on `:lua_vm`. See
    "Where the backends differ" below; the difference is observable to a script.
  - **Memory**: a `:max_heap_size` with `kill: true` on the process holding the
    Lua heap kills an allocation bomb the instant it exceeds the ceiling, before
    it can OOM the node.
  - **Wall-clock**: an outer `Task` backstop bounds total runtime (plus, on
    `:luerl` only, the sandbox's own `max_time` inside it).
  - **Crash isolation**: the script runs under `Task.Supervisor.async_nolink`, so
    a sandbox crash/kill surfaces as an error to the caller instead of taking the
    caller down with it.

  The three resource axes are expressed in the runtime-neutral
  `AshIntegration.Outbound.Delivery.Transform.Limits` vocabulary
  (`max_steps`, `max_memory_words`, `timeout_ms`) and mapped onto whichever
  primitives the compiled-against backend actually offers — see `Compat`.
  Limits are configurable (with safe defaults):

      config :ash_integration,
        lua_sandbox: [
          timeout_ms:     5_000,
          max_steps:      100_000_000,
          max_heap_words: 50_000_000
        ]

  `:max_reductions` is still accepted as a deprecated alias for `:max_steps`;
  it named luerl's own flag, which the `:lua_vm` backend does not have.

  ## Where the backends differ

  `Compat` documents this in full; the security-relevant part belongs here too,
  because it is a property of *this* sandbox and not an implementation detail:

  - On **`:luerl`**, the step budget is enforced by **killing** the process the
    Lua code runs in. Nothing inside Lua can observe or survive that, so a
    runaway script always ends in `{:error, …}` and the delivery parks.
  - On **`:lua_vm`**, it is enforced by **raising a Lua error**, which `pcall`
    **catches**. Total CPU is still bounded (the budget is per top-level
    evaluation and is never refilled, so the next loop back-edge re-raises), but
    a script can burn its whole budget, catch the error, and still return a
    normal result. The same source that parks on `:luerl` can deliver on
    `:lua_vm`.

  Two guarantees also change *where* they are enforced. `lua 1.0` has no
  `max_time` equivalent, so on `:lua_vm` the outer `Task` is the **only**
  wall-clock enforcement point rather than a backstop behind the sandbox's own
  timer. And because `:lua_vm` evaluates in-process, the memory ceiling is the
  `Task`'s own `:max_heap_size` rather than `spawn_opts` on a luerl runner — the
  runtime sets that flag on both backends, so the ceiling holds either way.

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
  so `warn_about_host_apis/0` flags both shapes at boot.

  Three properties hold this together:

  - **Host APIs must be pure computation** — no I/O, no network, no filesystem.
    The threat model is "operator-authored but untrusted at runtime", and a
    function that can reach outside the sandbox breaks it for every script on the
    node. Time-zone math qualifies; anything that opens a socket does not. This
    is a contract with the host, not something the runtime can enforce: a
    configured module runs with the full authority of the node.
  - **A host function that burns CPU is inside the budget.** It is invoked by
    whichever process is running the Lua code — luerl's runner on `:luerl`, the
    `Task` itself on `:lua_vm` — so its work and its allocations count against
    the same step and heap ceilings as the script's own: calling one in a tight
    loop is bounded exactly like a tight loop of Lua. A host function that
    **blocks** is the awkward case, and it is where the two backends diverge:

      * On `:luerl` it escapes both budgets. The reduction watchdog polls
        `process_info(runner, :reductions)`, and a descheduled runner never
        advances, so it never trips the step budget and never reaches the
        `max_time` check either. Only the outer `Task` backstop returns — and
        because the runner is spawned *unlinked*, brutal-killing that `Task`
        leaves it alive, leaking one process per delivery for as long as the call
        blocks.
      * On `:lua_vm` the evaluator *is* the `Task`, so `Task.shutdown(:brutal_kill)`
        actually kills it and nothing leaks.

    Either way a blocking host function defeats the step budget, which is the
    sharpest reason the purity rule above is a rule and not a preference.
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
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.DatetimeAPI

  # Always loaded, ahead of any host-configured API.
  @builtin_apis [DatetimeAPI]

  @doc """
  Boot check (from `AshIntegration.Supervisor`): warn about a
  `lua_sandbox: [apis: …]` entry that isn't a loadable `Lua.API` module, one that
  claims a built-in's scope and so replaces it, or two entries that claim the same
  scope as each other and so replace one another.

  All three are otherwise invisible until a transform runs — the first parks
  every delivery, the other two silently remove functions scripts were calling.
  This **warns rather than raises**, following
  `AshIntegration.Outbound.PoolCheck`: refusing the host's boot over a
  transform-sandbox setting is a heavier failure than the one it prevents, and a
  node that never runs a transform is unaffected. Every run still validates a
  module before loading it, so a bad entry parks with the same message rather
  than slipping through.
  """
  @spec warn_about_host_apis() :: :ok
  def warn_about_host_apis do
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

  # `parse_chunk/1` is one of the two places the stable API is NOT literally
  # identical: `lua 0.4` answers `{:error, [String.t()]}`, `lua 1.0` answers
  # `{:error, %Lua.CompilerException{}}`. Both shapes are matched here rather than
  # in `Compat` because both clauses compile on both versions (the struct exists
  # in each) — there is no conditional compilation to isolate. `to_string/1` on an
  # exception struct RAISES, so the list clause alone would crash on `lua 1.0`.
  defp format_errors(error) when is_exception(error), do: Exception.message(error)

  defp format_errors(errors), do: errors |> List.wrap() |> Enum.map_join("; ", &to_string/1)

  @impl true
  def execute(script, _event, _defaults, _limits) when byte_size(script) > @max_script_size do
    {:error, "script exceeds maximum size of #{@max_script_size} bytes"}
  end

  def execute(script, event, defaults, %Limits{} = limits) do
    task =
      Task.Supervisor.async_nolink(AshIntegration.TaskSupervisor, fn ->
        # This flag is doing two jobs. On `:lua_vm` it IS the memory ceiling —
        # that backend evaluates in this very process. On `:luerl` the runner
        # carries its own `:max_heap_size`, but that only bounds script
        # *execution*: reading and decoding the `result` table
        # (read_result/decode_result) runs here in the Task after the runner
        # returns, so a script that builds a within-budget-but-huge `result` could
        # balloon this process's heap outside that ceiling.
        # (kill: true → surfaces as `{:exit, _}`.)
        Process.flag(:max_heap_size, %{
          size: limits.max_memory_words,
          kill: true,
          error_logger: false
        })

        run_sandboxed(script, event, defaults, limits)
      end)

    # Outer wall-clock backstop. On `:luerl` it allows a grace second over the
    # sandbox's own `max_time`, so the sandbox returns its classified resource
    # error rather than losing the race to an opaque killed-task exit; on
    # `:lua_vm` there is no inner timer, so this IS the wall-clock ceiling and the
    # grace is zero (see `Compat.wall_clock_grace_ms/0`). Because the task is
    # `async_nolink`, a brutal-kill or crash here comes back as `{:exit, _}` —
    # never propagated to (and crashing) the caller.
    case Task.yield(task, wall_clock_ms(limits)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, "transform sandbox crashed or was killed"}
      nil -> {:error, "script execution timed out after #{limits.timeout_ms}ms"}
    end
  end

  defp wall_clock_ms(%Limits{} = limits),
    do: limits.timeout_ms + Compat.wall_clock_grace_ms()

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

    # ONE wall-clock backstop for the whole signing pipeline (all callbacks share
    # it), so a pathological source can't multiply latency by the number of
    # callbacks the way per-call Tasks would.
    case Task.yield(task, wall_clock_ms(limits)) || Task.shutdown(task, :brutal_kill) do
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
    case Compat.eval(lua, source <> @detect_callbacks, limits, "signing source") do
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

      case Compat.eval(lua, "__sign_result = #{fname}(__ctx)", limits, "signing callback") do
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
  # state and reads the outcome back; `Compat.eval/4` is the bounded execution
  # call (a luerl-spawned runner on `:luerl`, an in-process VM run on `:lua_vm`)
  # and classifies every failure into one message vocabulary.
  defp run_sandboxed(script, event, defaults, %Limits{} = limits) do
    with {:ok, lua} <- new_state(limits) do
      lua =
        lua
        |> set_global(:event, event)
        |> maybe_set_global(:defaults, defaults)

      # The author's source defines `transform`; @invoke calls it (or passes the
      # defaults through, for a no-op script) and stashes the RETURN value in the
      # bridge global we read back. Both run under the one bounded sandbox call.
      case Compat.eval(lua, script <> @invoke, limits, "script") do
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
  # reaches `Compat.new_state/1` because on the `:lua_vm` backend the CPU ceiling
  # is an option ON the state; on `:luerl` it rides with the execution call
  # instead and this is a plain `Lua.new/0`.
  defp new_state(%Limits{} = limits) do
    {:ok, Enum.reduce(host_apis(), Compat.new_state(limits), &load_host_api/2)}
  rescue
    # The only thing `load_host_api/2` itself raises — attribute it precisely.
    e in ArgumentError ->
      {:error, "could not load the configured Lua host APIs: #{Exception.message(e)}"}

    # Anything else (a module's `install/3`, `Lua.new/1`) is a different failure and
    # shouldn't be reported as a bad `:apis` config.
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

  # Lua/luerl returns a sequence (array) table as an integer-keyed proplist
  # (`[{1, v1}, {2, v2}, ...]`). Decode it to an ordered list of decoded values.
  defp sequence_table?([{k, _v} | _]) when is_integer(k), do: true
  defp sequence_table?(_), do: false

  # ── Config ──────────────────────────────────────────────────────────────

  defp sandbox_config,
    do: Keyword.get(Application.get_all_env(:ash_integration), :lua_sandbox, [])

  # The built-ins always load; host-configured APIs load after them. A host scope
  # that collides with a built-in's therefore REPLACES it wholesale (`Lua.load_api/2`
  # resets the scope table rather than merging), which `warn_about_host_apis/0`
  # surfaces at boot because the far likelier cause is an accidental name clash.
  defp host_apis, do: @builtin_apis ++ configured_apis()

  defp configured_apis, do: List.wrap(Keyword.get(sandbox_config(), :apis, []))

  defp timeout_ms, do: Keyword.get(sandbox_config(), :timeout_ms, @default_timeout_ms)

  # `:max_reductions` named luerl's own flag, which the `:lua_vm` backend has no
  # equivalent for. `:max_steps` (the `Limits` vocabulary) is the name to use; the
  # old key stays honoured so a host that set it keeps its configured ceiling
  # rather than silently reverting to the default.
  defp max_steps do
    config = sandbox_config()

    Keyword.get(config, :max_steps) || Keyword.get(config, :max_reductions) ||
      @default_max_steps
  end

  defp max_heap_words, do: Keyword.get(sandbox_config(), :max_heap_words, @default_max_heap_words)
end
