defmodule AshIntegration.OutboundIntegrations.SampleBuilder do
  @moduledoc """
  Builds authorization-aware sample event data.

  Given a fully-populated sample Ash struct, recursively walks its
  relationships and nils out any that the actor cannot read according
  to Ash policies. The filtered struct is then passed through the
  loader's transform function — which handles nil gracefully, exactly
  as it does for real data where Ash policies blocked access.
  """

  alias AshIntegration.OutboundIntegrations.Info

  @doc """
  Builds sample event data that respects the actor's authorization.

  1. Calls `loader.build_sample_resource(schema_version, action)` to get a full sample struct
  2. Recursively filters relationships using `Ash.can/3` with `alter_source?: true` to
     inspect authorization filters — nils out relationships with impossible (`false`) filters
  3. Calls `loader.transform_event_data(filtered_struct, action, schema_version)`
  """
  def build_sample_event_data(resource_identifier, schema_version, action, actor) do
    with resource_module when not is_nil(resource_module) <-
           Info.resource_module(resource_identifier),
         loader when not is_nil(loader) <- Info.loader(resource_module),
         action_atom when not is_nil(action_atom) <-
           Info.action_atom(resource_module, action) do
      sample_struct = loader.build_sample_resource(schema_version, action_atom)
      filtered_struct = filter_unauthorized(sample_struct, actor)
      {:ok, loader.transform_event_data(filtered_struct, action_atom, schema_version)}
    else
      _ -> {:error, :unable_to_build_sample}
    end
  end

  @doc false
  # Public for testing. Recursively walks an Ash struct's relationships
  # and nils out any where the actor cannot read the destination resource.
  # For authorized relationships, recurses into the loaded value to filter
  # nested relationships too.
  def filter_unauthorized(struct, actor) when is_struct(struct) do
    if ash_resource?(struct.__struct__) do
      struct.__struct__
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce(struct, fn rel, acc ->
        value = Map.get(acc, rel.name)

        cond do
          not should_filter?(value) ->
            acc

          not can_read?(rel, actor) ->
            Map.put(acc, rel.name, nil)

          is_list(value) ->
            Map.put(acc, rel.name, Enum.map(value, &filter_unauthorized(&1, actor)))

          true ->
            Map.put(acc, rel.name, filter_unauthorized(value, actor))
        end
      end)
    else
      # Non-Ash struct (e.g., embedded resources) — always included as-is,
      # they don't have Ash policies
      struct
    end
  end

  def filter_unauthorized(other, _actor), do: other

  # Should we check this value for authorization?
  # nil and NotLoaded don't need filtering — they aren't populated data.
  # Empty lists ARE loaded data (a has_many with zero results), so they
  # return true — the is_list branch will Enum.map over [] harmlessly.
  defp should_filter?(nil), do: false
  defp should_filter?(%Ash.NotLoaded{}), do: false
  defp should_filter?(_), do: true

  # Check if the actor can read this relationship's destination resource
  # by inspecting the authorization filter Ash would apply.
  #
  # Uses `alter_source?: true` so Ash returns the query with auth filters
  # baked in, instead of just true/false. Then we check if the filter is
  # literally `false` (impossible — actor has zero access) vs anything else
  # (conditional or full access — show the data conservatively).
  #
  # Passes `accessing_from` context so policies like
  # `authorize_if accessing_from(Source, :rel_name)` resolve correctly.
  defp can_read?(rel, actor) do
    resource = rel.destination
    read_action = rel.read_action || primary_read_action(resource)

    can_opts = [
      alter_source?: true,
      run_queries?: false,
      context: %{accessing_from: %{source: rel.source, name: rel.name}}
    ]

    case Ash.can({resource, read_action}, actor, can_opts) do
      {:ok, true, %{filter: filter}} ->
        not impossible_filter?(filter)

      {:ok, false, _} ->
        false

      {:ok, false} ->
        false

      _ ->
        # On error or unexpected result, conservatively show the data
        true
    end
  end

  defp impossible_filter?(nil), do: false
  defp impossible_filter?(%{expression: false}), do: true
  defp impossible_filter?(_), do: false

  defp primary_read_action(resource) do
    resource
    |> Ash.Resource.Info.primary_action(:read)
    |> Map.get(:name)
  end

  defp ash_resource?(module) do
    Spark.Dsl.is?(module, Ash.Resource)
  end
end
