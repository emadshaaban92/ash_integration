defmodule AshIntegration.OutboundIntegrations.Info do
  @moduledoc """
  Introspection helpers for the `outbound_integrations` DSL.
  """

  def outbound_resources do
    AshIntegration.otp_app()
    |> Ash.Info.domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&configured?/1)
  end

  def configured?(resource) do
    not is_nil(resource_identifier(resource)) and not is_nil(loader(resource))
  end

  def resource_identifier(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:outbound_integrations], :resource_identifier)
  end

  def resource_module(resource_identifier) when is_binary(resource_identifier) do
    Enum.find(outbound_resources(), &(resource_identifier(&1) == resource_identifier))
  end

  def loader(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:outbound_integrations], :loader)
  end

  def actions(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:outbound_integrations])
  end

  def action_names(resource) do
    Enum.map(actions(resource), &to_string(&1.name))
  end

  def supported_versions(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:outbound_integrations], :supported_versions)
    |> List.wrap()
    |> Enum.sort()
  end

  def latest_version(resource) do
    resource
    |> supported_versions()
    |> Enum.max(fn -> nil end)
  end

  def action_type(resource, action_name) do
    case action_atom(resource, action_name) do
      nil -> nil
      action_atom -> resource |> Ash.Resource.Info.action(action_atom) |> Map.get(:type)
    end
  end

  def supports_action?(resource, action_name) do
    not is_nil(action_entity(resource, action_name))
  end

  def supports_version?(resource, version) do
    version in supported_versions(resource)
  end

  def action_atom(resource, action_name) do
    case action_entity(resource, action_name) do
      nil -> nil
      action -> action.name
    end
  end

  def sample_event(resource_identifier, schema_version)
      when is_binary(resource_identifier) do
    case resource_module(resource_identifier) do
      nil -> nil
      resource -> loader(resource).sample_event(schema_version)
    end
  end

  defp action_entity(resource, action_name) do
    action_name = to_string(action_name)

    Enum.find(actions(resource), &(to_string(&1.name) == action_name))
  end
end
