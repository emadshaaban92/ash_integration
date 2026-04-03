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
  2. Recursively filters relationships based on `Ash.can?({destination, read_action}, actor)`
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

  # Use the relationship's configured read_action, or fall back to
  # the destination resource's primary read action. This matches
  # what Ash would use when loading the relationship.
  defp can_read?(rel, actor) do
    read_action = rel.read_action || primary_read_action(rel.destination)

    Ash.can?({rel.destination, read_action}, actor,
      run_queries?: false,
      reuse_values?: true,
      maybe_is: true
    )
  end

  defp primary_read_action(resource) do
    resource
    |> Ash.Resource.Info.primary_action(:read)
    |> Map.get(:name)
  end

  defp ash_resource?(module) do
    Spark.Dsl.is?(module, Ash.Resource)
  end
end
