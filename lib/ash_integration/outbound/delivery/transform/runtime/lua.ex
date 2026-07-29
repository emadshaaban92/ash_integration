defmodule AshIntegration.Outbound.Delivery.Transform.Runtime.Lua do
  @max_script_size 10_240
  @default_timeout_ms 5_000
  # ~100M reductions ≈ a fraction of a second of runaway CPU before the kill (the
  # luerl reduction poll is coarse, so the practical bound is "a brief spin", and
  # the outer wall-clock backstop catches anything that slips past).
  @default_max_reductions 100_000_000
  # Heap+stack ceiling for the runner, in WORDS (≈8 bytes each on 64-bit, so the
  # default is ~400MB). Exceeding it kills the runner instantly — an allocation
  # bomb can't OOM the node while waiting for the wall-clock timeout.
  @default_max_heap_words 50_000_000

  @moduledoc """
  Sandboxed Lua execution environment for outbound transform scripts.

  This is the `:lua` implementation of the
  `AshIntegration.Outbound.Delivery.Transform.Runtime` behaviour — the in-process,
  luerl-backed transform engine. The resolver reaches it through that
  behaviour (never by name), so a future runtime can slot in beside it.

  Transform scripts are **operator-authored but untrusted at runtime** (a typo, a
  pathological loop, or hostile event data flowing into the script). Execution is
  bounded on three axes so one script can't take down the node:

  - **Function sandboxing** (`Lua.new/0`): `io`, `os.execute`, `os.exit`,
    `os.getenv`, `package`, `load`, `require`, `dofile`, … all raise if called.
  - **Script size**: scripts over #{@max_script_size} bytes are rejected up front.
  - **CPU / reductions**: a luerl `max_reductions` budget kills a runaway loop.
  - **Memory**: a per-runner `:max_heap_size` (`spawn_opts`) kills an allocation
    bomb the instant it exceeds the heap ceiling, before it can OOM the node.
  - **Wall-clock**: a luerl `max_time` plus an outer `Task` backstop bound total
    runtime.
  - **Crash isolation**: the script runs under `Task.Supervisor.async_nolink`, so
    a sandbox crash/kill surfaces as an error to the caller instead of taking the
    caller down with it.

  The three resource axes are expressed in the runtime-neutral
  `AshIntegration.Outbound.Delivery.Transform.Limits` vocabulary and mapped
  onto luerl's native flags here (`max_steps → max_reductions`,
  `max_memory_words → :max_heap_size`, `timeout_ms → max_time`). Limits are
  configurable (with safe defaults):

      config :ash_integration,
        lua_sandbox: [
          timeout_ms:     5_000,
          max_reductions: 100_000_000,
          max_heap_words: 50_000_000
        ]

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

  Built-ins load first, host modules after. **A host scope that collides with a
  built-in's replaces it entirely** — `Lua.load_api/2` resets the scope table
  rather than merging into it, so a host module scoped `datetime` removes
  `datetime.to_zone`/`datetime.format` for every script on the node. That is
  occasionally what a host wants; far more often it's an accidental name clash,
  so `warn_about_host_apis/0` flags it at boot.

  Three properties hold this together:

  - **Host APIs must be pure computation** — no I/O, no network, no filesystem.
    The threat model is "operator-authored but untrusted at runtime", and a
    function that can reach outside the sandbox breaks it for every script on the
    node. Time-zone math qualifies; anything that opens a socket does not. This
    is a contract with the host, not something the runtime can enforce: a
    configured module runs with the full authority of the node.
  - **A host function that burns CPU is inside the budget.** It is invoked by the
    luerl *runner* process, so its reductions and its allocations count against
    the same `max_reductions` / `:max_heap_size` ceilings as the script's own
    work — calling one in a tight loop is bounded exactly like a tight loop of
    Lua. A host function that **blocks**, however, escapes both: luerl's reduction
    watchdog polls `process_info(runner, :reductions)`, and a descheduled runner
    never advances, so it never trips `max_reductions` and never reaches the
    `max_time` check either. Only the outer `Task` backstop returns — and because
    the runner is spawned unlinked, brutal-killing that `Task` leaves it alive,
    leaking one process per delivery for as long as the call blocks. This is the
    sharpest reason the purity rule above is a rule and not a preference.
  - **A script can shadow them, and that hurts only itself.** The APIs are loaded
    before the author's chunk, so `datetime = nil` at the top of a script is
    legal. Every run builds a fresh `Lua.new/0` and re-loads the APIs into it, so
    a mutated global cannot leak into the next execution — there is no state
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
  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.DatetimeAPI

  # Always loaded, ahead of any host-configured API.
  @builtin_apis [DatetimeAPI]

  @doc """
  Boot check (from `AshIntegration.Supervisor`): warn about a
  `lua_sandbox: [apis: …]` entry that isn't a loadable `Lua.API` module, or that
  claims a built-in's scope and so replaces it.

  Both failures are otherwise invisible until a transform runs — the first parks
  every delivery, the second silently removes functions scripts were calling.
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

  # `[{name, with_state?, variadic?}, …]` — what `use Lua.API` records for a module.
  defp scoped_names(builtin, scope) do
    Enum.map_join(builtin.__lua_functions__(), ", ", fn {name, _state?, _variadic?} ->
      "#{scope}.#{name}"
    end)
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
      max_steps: max_reductions(),
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

  defp format_errors(errors), do: errors |> List.wrap() |> Enum.map_join("; ", &to_string/1)

  @impl true
  def execute(script, _event, _defaults, _limits) when byte_size(script) > @max_script_size do
    {:error, "script exceeds maximum size of #{@max_script_size} bytes"}
  end

  def execute(script, event, defaults, %Limits{} = limits) do
    task =
      Task.Supervisor.async_nolink(AshIntegration.TaskSupervisor, fn ->
        # The luerl runner's own `:max_heap_size` only bounds script *execution*.
        # Reading and decoding the `result` table (read_result/decode_result) runs
        # here in the Task, after the runner returns — so a script that builds a
        # within-budget-but-huge `result` could balloon this process's heap, outside
        # that ceiling. Cap the Task heap too (kill: true → surfaces as `{:exit, _}`).
        Process.flag(:max_heap_size, %{
          size: limits.max_memory_words,
          kill: true,
          error_logger: false
        })

        run_sandboxed(script, event, defaults, limits)
      end)

    # Outer wall-clock backstop, slightly longer than the inner luerl `max_time`
    # so the sandbox returns its own classified resource error first. Because the
    # task is `async_nolink`, a brutal-kill or crash here comes back as `{:exit, _}`
    # — never propagated to (and crashing) the caller.
    case Task.yield(task, limits.timeout_ms + 1_000) || Task.shutdown(task, :brutal_kill) do
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

    # ONE wall-clock backstop for the whole signing pipeline (all callbacks share
    # it), so a pathological source can't multiply latency by the number of
    # callbacks the way per-call Tasks would.
    case Task.yield(task, limits.timeout_ms + 1_000) || Task.shutdown(task, :brutal_kill) do
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
    with {:ok, lua} <- new_state() do
      compile_session(source, lua, sandbox_flags(limits), orchestrate)
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end

  defp compile_session(source, lua, flags, orchestrate) do
    case :luerl_sandbox.run(source <> @detect_callbacks, flags, lua.state) do
      {:ok, _results, state} ->
        defined = read_defined(state)
        orchestrate.(fn fname, ctx -> sign_call_on(state, flags, defined, fname, ctx) end)

      other ->
        {:error, classify_sandbox_error(other)}
    end
  end

  # Invoke one already-compiled callback on the shared state. An undefined callback
  # short-circuits to `:undefined` with no sandbox run at all.
  defp sign_call_on(state, flags, defined, fname, ctx) do
    if MapSet.member?(defined, fname) do
      lua = set_global(%Lua{state: state}, :__ctx, ctx)

      case :luerl_sandbox.run("__sign_result = #{fname}(__ctx)", flags, lua.state) do
        {:ok, _results, state} ->
          {:ok, {:defined, decode_result(Lua.get!(%Lua{state: state}, [:__sign_result]))}}

        other ->
          {:error, classify_sandbox_error(other)}
      end
    else
      {:ok, :undefined}
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end

  defp read_defined(state) do
    case Lua.get!(%Lua{state: state}, [:__sign_defined]) do
      table when is_list(table) ->
        for {k, true} <- table, into: MapSet.new(), do: to_string(k)

      _ ->
        MapSet.new()
    end
  end

  defp sandbox_flags(%Limits{} = limits) do
    %{
      max_reductions: limits.max_steps,
      max_time: limits.timeout_ms,
      spawn_opts: [
        {:max_heap_size, %{size: limits.max_memory_words, kill: true, error_logger: false}}
      ]
    }
  end

  defp classify_sandbox_error({:lua_error, _reason, _state} = error),
    do: Exception.message(Lua.RuntimeException.exception(error))

  defp classify_sandbox_error({:error, errors, _state}) when is_list(errors),
    do: Exception.message(Lua.CompilerException.exception(errors))

  defp classify_sandbox_error({:error, {:reductions, count}}),
    do: "signing callback exceeded the reduction budget (killed after #{count} reductions)"

  defp classify_sandbox_error({:error, :timeout}),
    do: "signing callback timed out or exceeded its memory budget"

  # A host API function that raises (e.g. `datetime.to_zone` on an unknown zone)
  # comes back as the exception struct itself — surface its message, not its guts.
  defp classify_sandbox_error({:error, %Lua.RuntimeException{} = exception}),
    do: Exception.message(exception)

  defp classify_sandbox_error({:error, %Lua.CompilerException{} = exception}),
    do: Exception.message(exception)

  defp classify_sandbox_error({:error, reason}),
    do: "signing callback error: #{inspect(reason)}"

  defp classify_sandbox_error(other), do: "signing callback error: #{inspect(other)}"

  # Runs inside the async_nolink task. The actual Lua evaluation happens in a
  # FURTHER luerl-spawned runner (carrying the reduction + heap limits); this
  # function only builds the pre-seeded state and classifies the outcome.
  defp run_sandboxed(script, event, defaults, %Limits{} = limits) do
    with {:ok, lua} <- new_state() do
      lua =
        lua
        |> set_global(:event, event)
        |> maybe_set_global(:defaults, defaults)

      # The author's source defines `transform`; @invoke calls it (or passes the
      # defaults through, for a no-op script) and stashes the RETURN value in the
      # bridge global we read back. Both run under the one bounded sandbox call.
      case :luerl_sandbox.run(script <> @invoke, sandbox_flags(limits), lua.state) do
        {:ok, _results, state} ->
          read_result(state)

        {:lua_error, _reason, _state} = error ->
          {:error, Exception.message(Lua.RuntimeException.exception(error))}

        {:error, errors, _state} when is_list(errors) ->
          {:error, Exception.message(Lua.CompilerException.exception(errors))}

        {:error, {:reductions, count}} ->
          {:error, "script exceeded the reduction budget (killed after #{count} reductions)"}

        {:error, :timeout} ->
          {:error, "script execution timed out or exceeded its memory budget"}

        {:error, %Lua.RuntimeException{} = exception} ->
          {:error, Exception.message(exception)}

        {:error, %Lua.CompilerException{} = exception} ->
          {:error, Exception.message(exception)}

        {:error, reason} ->
          {:error, "script error: #{inspect(reason)}"}
      end
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end

  # The transform's return value (`nil` → skip the event).
  defp read_result(state) do
    case Lua.get!(%Lua{state: state}, [@result_global]) do
      nil -> {:ok, :skip}
      result -> {:ok, decode_result(result)}
    end
  end

  # A FRESH sandbox state per run, with the built-in and host-configured APIs
  # loaded into it. Nothing is carried over between runs, so a script that
  # shadows or clobbers an API global affects only its own execution.
  defp new_state do
    {:ok, Enum.reduce(host_apis(), Lua.new(), &load_host_api/2)}
  rescue
    # The only thing `load_host_api/2` itself raises — attribute it precisely.
    e in ArgumentError ->
      {:error, "could not load the configured Lua host APIs: #{Exception.message(e)}"}

    # Anything else (a module's `install/3`, `Lua.new/0`) is a different failure and
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
  defp max_reductions, do: Keyword.get(sandbox_config(), :max_reductions, @default_max_reductions)
  defp max_heap_words, do: Keyword.get(sandbox_config(), :max_heap_words, @default_max_heap_words)
end
