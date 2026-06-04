defmodule AshIntegration.Outbound.Delivery.LuaSandbox do
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

  Limits are configurable (with safe defaults):

      config :ash_integration,
        lua_sandbox: [
          timeout_ms:     5_000,
          max_reductions: 100_000_000,
          max_heap_words: 50_000_000
        ]

  Scripts receive event data as a global `event` table and produce output by
  mutating a global `result` variable. The caller may **pre-seed** `result` (via
  the `:result` option) with the transport-shaped delivery defaults, so a no-op
  script sends those defaults and the script only has to express overrides. If the
  script sets `result` to nil, the event is skipped.
  """

  def execute(script, event_data, opts \\ [])

  def execute(script, _event_data, _opts) when byte_size(script) > @max_script_size do
    {:error, "script exceeds maximum size of #{@max_script_size} bytes"}
  end

  def execute(script, event_data, opts) do
    preseed = Keyword.get(opts, :result)

    task =
      Task.Supervisor.async_nolink(AshIntegration.TaskSupervisor, fn ->
        run_sandboxed(script, event_data, preseed)
      end)

    # Outer wall-clock backstop, slightly longer than the inner luerl `max_time`
    # so the sandbox returns its own classified resource error first. Because the
    # task is `async_nolink`, a brutal-kill or crash here comes back as `{:exit, _}`
    # — never propagated to (and crashing) the caller.
    case Task.yield(task, timeout_ms() + 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, "transform sandbox crashed or was killed"}
      nil -> {:error, "script execution timed out after #{timeout_ms()}ms"}
    end
  end

  # Runs inside the async_nolink task. The actual Lua evaluation happens in a
  # FURTHER luerl-spawned runner (carrying the reduction + heap limits); this
  # function only builds the pre-seeded state and classifies the outcome.
  defp run_sandboxed(script, event_data, preseed) do
    lua =
      Lua.new()
      |> set_global(:event, event_data)
      |> set_preseed(preseed)

    flags = %{
      max_reductions: max_reductions(),
      max_time: timeout_ms(),
      spawn_opts: [{:max_heap_size, %{size: max_heap_words(), kill: true, error_logger: false}}]
    }

    case :luerl_sandbox.run(script, flags, lua.state) do
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

  defp read_result(state) do
    case Lua.get!(%Lua{state: state}, [:result]) do
      nil -> {:ok, :skip}
      result -> {:ok, decode_result(result)}
    end
  end

  defp set_global(lua, key, data) do
    {encoded, lua} = Lua.encode!(lua, stringify_keys(data))
    Lua.set!(lua, [key], encoded)
  end

  defp set_preseed(lua, nil), do: lua
  defp set_preseed(lua, preseed), do: set_global(lua, :result, preseed)

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
