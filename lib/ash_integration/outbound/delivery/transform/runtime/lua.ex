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

  alias AshIntegration.Outbound.Delivery.Transform.Limits

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
    flags = sandbox_flags(limits)

    case :luerl_sandbox.run(source <> @detect_callbacks, flags, Lua.new().state) do
      {:ok, _results, state} ->
        defined = read_defined(state)
        orchestrate.(fn fname, ctx -> sign_call_on(state, flags, defined, fname, ctx) end)

      other ->
        {:error, classify_sandbox_error(other)}
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
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

  defp classify_sandbox_error({:error, reason}),
    do: "signing callback error: #{inspect(reason)}"

  defp classify_sandbox_error(other), do: "signing callback error: #{inspect(other)}"

  # Runs inside the async_nolink task. The actual Lua evaluation happens in a
  # FURTHER luerl-spawned runner (carrying the reduction + heap limits); this
  # function only builds the pre-seeded state and classifies the outcome.
  defp run_sandboxed(script, event, defaults, %Limits{} = limits) do
    lua =
      Lua.new()
      |> set_global(:event, event)
      |> maybe_set_global(:defaults, defaults)

    flags = %{
      max_reductions: limits.max_steps,
      max_time: limits.timeout_ms,
      spawn_opts: [
        {:max_heap_size, %{size: limits.max_memory_words, kill: true, error_logger: false}}
      ]
    }

    # The author's source defines `transform`; @invoke calls it (or passes the
    # defaults through, for a no-op script) and stashes the RETURN value in the
    # bridge global we read back. Both run under the one bounded sandbox call.
    case :luerl_sandbox.run(script <> @invoke, flags, lua.state) do
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

  defp timeout_ms, do: Keyword.get(sandbox_config(), :timeout_ms, @default_timeout_ms)
  defp max_reductions, do: Keyword.get(sandbox_config(), :max_reductions, @default_max_reductions)
  defp max_heap_words, do: Keyword.get(sandbox_config(), :max_heap_words, @default_max_heap_words)
end
