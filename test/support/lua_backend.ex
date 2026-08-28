defmodule AshIntegration.Test.LuaBackend do
  @moduledoc """
  Which Lua backend the suite is running against, derived at **run time**.

  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat.backend/0` is a
  compile-time constant, which is exactly what the runtime wants and exactly what
  a *test* cannot branch on: the compiler folds it, flags the other backend's
  branch as unreachable, and `mix test --warnings-as-errors` fails the run for
  whichever backend is not installed. Reading the loaded `:lua` application's
  version instead keeps both branches live for the compiler while still selecting
  the right one at run time.

  These two answers must not drift, so `lua_sandbox_limits_test.exs` asserts they
  agree — if `Compat`'s compile-time detection ever disagreed with the `:lua`
  version actually loaded, that assertion is where it surfaces.
  """

  @doc """
  `:lua_vm` on `lua 1.0`, `:luerl` on `lua 0.4`.

  The requirement must stay byte-identical to `Compat`'s, `">= 1.0.0-0"` and not
  `">= 1.0.0"`: Elixir excludes pre-releases from a requirement carrying none, so
  the shorter form answers `:luerl` for a `1.0.0-rc`. Both gates agreeing on the
  *wrong* answer would keep the agreement test green while every delivery parked.
  """
  @spec backend() :: :lua_vm | :luerl
  def backend do
    if Version.match?(to_string(Application.spec(:lua, :vsn)), ">= 1.0.0-0") do
      :lua_vm
    else
      :luerl
    end
  end

  @doc "True on `lua 0.4` (Erlang luerl, `:luerl_sandbox`-bounded)."
  @spec luerl?() :: boolean()
  def luerl?, do: backend() == :luerl

  @doc "True on `lua 1.0` (the `lua` package's own Elixir Lua VM)."
  @spec lua_vm?() :: boolean()
  def lua_vm?, do: backend() == :lua_vm
end
