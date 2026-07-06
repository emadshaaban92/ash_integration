defmodule AshIntegration.Inbound.Declare.Verifier do
  @moduledoc false
  # Compile-time, per-mention checks (Spark verifiers are module-local, so
  # cross-module uniqueness + handler-callback checks are done centrally at boot by
  # `AshIntegration.Inbound.Declare.Registry.verify!/0`). For each `command` we
  # verify the named `action` actually exists on the resource — without it a typo
  # (`action :recrod_partner_ref`) compiles cleanly and silently produces a route
  # that can never apply.
  use Spark.Dsl.Verifier

  alias AshIntegration.Inbound.Declare.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    action_names =
      dsl_state
      |> Ash.Resource.Info.actions()
      |> MapSet.new(& &1.name)

    Enum.reduce_while(Info.commands(dsl_state), :ok, fn command, :ok ->
      action = Info.action(command)

      if MapSet.member?(action_names, action) do
        {:cont, :ok}
      else
        {:halt, {:error, missing_action_error(module, command, action, action_names)}}
      end
    end)
  end

  defp missing_action_error(module, command, action, action_names) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:inbound_commands, :command, Info.raw_command_type(command)],
      message:
        "command #{inspect(Info.raw_command_type(command))} names action #{inspect(action)}, " <>
          "which does not exist on #{inspect(module)}. Available actions: " <>
          "#{inspect(Enum.sort(MapSet.to_list(action_names)))}."
    )
  end
end
