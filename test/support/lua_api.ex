defmodule AshIntegration.Test.LuaAPI do
  @moduledoc """
  A host-registered Lua API, standing in for what a host app would put in
  `config :ash_integration, lua_sandbox: [apis: [...]]`.

  Pure computation over its arguments, like every host API must be. Note that
  `deflua/2` heads take no guards (the `lua` dep only parses a `when` clause in
  the state-carrying `deflua/3` form) — validate inside the body instead.
  """

  use Lua.API, scope: "myapp"

  deflua shout(text) do
    to_string(text) |> String.upcase() |> Kernel.<>("!")
  end

  deflua tenant_path(tenant, id) do
    "/t/" <> to_string(tenant) <> "/orders/" <> to_string(id)
  end

  deflua explode(reason) do
    raise ArgumentError, "host API blew up: #{reason}"
  end
end

defmodule AshIntegration.Test.CollidingLuaAPI do
  @moduledoc """
  A host API that claims the built-in `datetime` scope. `Lua.load_api/2` resets a
  scope table rather than merging into it, so loading this REPLACES the built-in
  outright — the case `warn_about_host_apis/0` flags at boot.
  """

  use Lua.API, scope: "datetime"

  deflua epoch_day(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(to_string(iso8601))
    datetime |> DateTime.to_date() |> Date.to_gregorian_days()
  end
end
