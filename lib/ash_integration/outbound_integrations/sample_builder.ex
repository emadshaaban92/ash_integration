defmodule AshIntegration.OutboundIntegrations.SampleBuilder do
  @moduledoc """
  Builds sample event data for outbound integration previews.

  Tries to load a real record first (via `sample_resource_id` + `load_resource`),
  falling back to a synthetic sample (via `build_sample_resource` + authorization
  filtering) if no real data is available.
  """

  alias AshIntegration.OutboundIntegrations.Info
  alias AshIntegration.EventDataLoader

  @doc """
  Builds sample event data using the best available strategy.

  1. **Real record** — if the loader implements `sample_resource_id/2` and a record
     is found, loads it via `EventDataLoader` with full Ash authorization.
  2. **Synthetic sample** — if no real record, and the loader implements
     `build_sample_resource/2`, builds a synthetic struct and filters unauthorized
     relationships.
  3. **Error** — if neither strategy is available, returns `{:error, :no_sample_data}`.
  """
  def build_sample_event_data(resource_identifier, schema_version, action, actor) do
    with resource_module when not is_nil(resource_module) <-
           Info.resource_module(resource_identifier),
         loader when not is_nil(loader) <- Info.loader(resource_module),
         action_atom when not is_nil(action_atom) <-
           Info.action_atom(resource_module, action) do
      case try_real_record(
             loader,
             resource_identifier,
             schema_version,
             action,
             action_atom,
             actor
           ) do
        {:ok, _data} = success ->
          success

        _no_real_record ->
          try_synthetic_sample(loader, schema_version, action_atom, actor)
      end
    else
      _ -> {:error, :no_sample_data}
    end
  end

  defp try_real_record(loader, resource_identifier, schema_version, action, action_atom, actor) do
    if function_exported?(loader, :sample_resource_id, 2) do
      case loader.sample_resource_id(actor, action_atom) do
        {:ok, resource_id} ->
          EventDataLoader.load_event_data(
            resource_identifier,
            resource_id,
            action,
            schema_version,
            actor
          )

        _error ->
          :no_real_record
      end
    else
      :no_real_record
    end
  end

  defp try_synthetic_sample(loader, schema_version, action_atom, actor) do
    if function_exported?(loader, :build_sample_resource, 2) do
      sample_struct = loader.build_sample_resource(schema_version, action_atom)
      filtered_struct = filter_unauthorized(sample_struct, actor)
      {:ok, loader.transform_event_data(filtered_struct, action_atom, schema_version)}
    else
      {:error, :no_sample_data}
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
