defmodule AshIntegration.LuaSandbox do
  @max_script_size 10_240
  @timeout_ms 5_000

  @moduledoc """
  Sandboxed Lua execution environment for outbound transform scripts.

  Security is enforced at multiple levels:

  - **Library sandboxing**: `Lua.new/0` automatically sandboxes dangerous functions
    including `io`, `file`, `os.execute`, `os.exit`, `os.getenv`, `os.remove`,
    `os.rename`, `os.tmpname`, `package`, `load`, `loadfile`, `require`, `dofile`,
    and `loadstring`. Calling any of these from a script raises a runtime error.
  - **Script size limit**: Scripts exceeding #{@max_script_size} bytes are rejected.
  - **Wall-clock timeout**: Execution is killed after #{@timeout_ms}ms via Task shutdown.

  Scripts receive event data as a global `event` table and produce output by setting
  a global `result` variable. If `result` is nil (not set), the event is skipped.
  """

  def execute(script, _event_data) when byte_size(script) > @max_script_size do
    {:error, "script exceeds maximum size of #{@max_script_size} bytes"}
  end

  def execute(script, event_data) do
    task =
      Task.async(fn ->
        try do
          run_script(script, event_data)
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "script execution timed out after #{@timeout_ms}ms"}
    end
  end

  defp run_script(script, event_data) do
    lua = Lua.new()
    {encoded, lua} = Lua.encode!(lua, stringify_keys(event_data))
    lua = Lua.set!(lua, [:event], encoded)

    {_, lua} = Lua.eval!(lua, script)

    case Lua.get!(lua, [:result]) do
      nil -> {:ok, :skip}
      result -> {:ok, decode_result(result)}
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp decode_result(table) when is_list(table) do
    if keyword_table?(table) do
      Map.new(table, fn {k, v} -> {k, decode_result(v)} end)
    else
      Enum.map(table, &decode_result/1)
    end
  end

  defp decode_result(value), do: value

  defp keyword_table?([{k, _v} | _]) when is_binary(k), do: true
  defp keyword_table?(_), do: false
end
