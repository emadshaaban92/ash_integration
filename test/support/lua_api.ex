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
end
