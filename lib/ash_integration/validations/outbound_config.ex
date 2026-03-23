defmodule AshIntegration.Validations.OutboundConfig do
  use Ash.Resource.Validation

  alias AshIntegration.OutboundIntegrations.Info

  @impl true
  def validate(changeset, _opts, _context) do
    resource_identifier = value(changeset, :resource)
    actions = value(changeset, :actions) || []
    schema_version = value(changeset, :schema_version)

    with {:ok, resource_module} <- validate_resource(resource_identifier),
         :ok <- validate_actions(resource_module, actions) do
      validate_schema_version(resource_module, schema_version)
    end
  end

  defp value(changeset, attribute) do
    case Map.fetch(changeset.attributes, attribute) do
      {:ok, value} -> value
      :error -> Map.get(changeset.data, attribute)
    end
  end

  defp validate_resource(resource_identifier) when is_binary(resource_identifier) do
    case Info.resource_module(resource_identifier) do
      nil -> {:error, field: :resource, message: "is not a supported outbound resource"}
      resource_module -> {:ok, resource_module}
    end
  end

  defp validate_resource(_), do: {:error, field: :resource, message: "is required"}

  defp validate_actions(_resource_module, []),
    do: {:error, field: :actions, message: "must include at least one action"}

  defp validate_actions(resource_module, actions) do
    normalized_actions = Enum.uniq(actions)

    case Enum.find(normalized_actions, &(not Info.supports_action?(resource_module, &1))) do
      nil -> :ok
      action -> {:error, field: :actions, message: "contains unsupported action #{action}"}
    end
  end

  defp validate_schema_version(_resource_module, nil),
    do: {:error, field: :schema_version, message: "is required"}

  defp validate_schema_version(resource_module, schema_version) do
    if Info.supports_version?(resource_module, schema_version) do
      :ok
    else
      {:error,
       field: :schema_version,
       message: "version #{schema_version} is not supported for this resource"}
    end
  end
end
