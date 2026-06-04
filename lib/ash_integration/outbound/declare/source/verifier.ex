defmodule AshIntegration.Outbound.Declare.Source.Verifier do
  @moduledoc false
  # Compile-time, per-mention checks (Spark verifiers are module-local, so
  # cross-mention consistency is checked centrally at boot by
  # `AshIntegration.Outbound.Declare.Registry.verify!/0`). For each `event` we verify:
  #
  #   * every action named in `actions` actually exists on the resource — without
  #     it a typo (`actions [:updatte]`) compiles cleanly and silently produces a
  #     trigger that never fires; and
  #   * at least one `version` is declared — a version is the unit a subscription
  #     binds to, so a versionless event lands in the catalog with an empty version
  #     set and is permanently un-subscribable (every version rejected by
  #     `SubscriptionEventType`) with no signal at compile or boot.
  use Spark.Dsl.Verifier

  alias AshIntegration.Outbound.Declare.Source.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    action_names =
      dsl_state
      |> Ash.Resource.Info.actions()
      |> MapSet.new(& &1.name)

    Enum.reduce_while(Info.events(dsl_state), :ok, fn event, :ok ->
      case verify_event(event, module, action_names) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_event(event, module, action_names) do
    event_type = Info.event_type(event)

    cond do
      Info.versions(event) == [] ->
        {:error, missing_versions_error(module, event_type)}

      missing = present_missing_actions(event, action_names) ->
        {:error, missing_actions_error(module, event_type, missing, action_names)}

      true ->
        :ok
    end
  end

  # Returns the list of declared actions that don't exist on the resource, or
  # `nil` when all exist (so it reads as a falsy branch in the `cond` above).
  defp present_missing_actions(event, action_names) do
    case Enum.reject(Info.actions(event), &MapSet.member?(action_names, &1)) do
      [] -> nil
      missing -> missing
    end
  end

  defp missing_versions_error(module, event_type) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:outbound_events, :event, event_type],
      message:
        "event #{inspect(event_type)} declares no `version`. Every event must declare at " <>
          "least one `version` (the unit a subscription binds to); otherwise it can never " <>
          "be subscribed to. Add e.g. `version 1`."
    )
  end

  defp missing_actions_error(module, event_type, missing, action_names) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:outbound_events, :event, event_type],
      message:
        "event #{inspect(event_type)} lists action(s) #{inspect(missing)} that do not exist " <>
          "on #{inspect(module)}. Available actions: #{inspect(Enum.sort(MapSet.to_list(action_names)))}."
    )
  end
end
