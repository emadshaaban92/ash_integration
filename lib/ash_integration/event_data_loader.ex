defmodule AshIntegration.EventDataLoader do
  alias AshIntegration.OutboundIntegrations.Info

  def load_event_data(resource_identifier, resource_id, action, schema_version, actor) do
    with {:ok, resource_module} <- fetch_resource_module(resource_identifier),
         :ok <- validate_action(resource_module, action),
         :ok <- validate_schema_version(resource_module, schema_version),
         loader when not is_nil(loader) <- Info.loader(resource_module),
         action_atom when not is_nil(action_atom) <- Info.action_atom(resource_module, action),
         {:ok, resource} <- loader.load_resource(resource_id, schema_version, actor) do
      {:ok, loader.transform_event_data(resource, action_atom, schema_version)}
    else
      nil -> {:error, {:missing_loader, resource_identifier}}
      {:error, _} = error -> error
    end
  end

  defp fetch_resource_module(resource_identifier) do
    case Info.resource_module(resource_identifier) do
      nil -> {:error, {:unsupported_resource, resource_identifier}}
      resource_module -> {:ok, resource_module}
    end
  end

  defp validate_action(resource_module, action) do
    if Info.supports_action?(resource_module, action) do
      :ok
    else
      {:error, {:unsupported_action, action}}
    end
  end

  defp validate_schema_version(resource_module, schema_version) do
    if Info.supports_version?(resource_module, schema_version) do
      :ok
    else
      {:error, {:unsupported_schema_version, schema_version}}
    end
  end
end
