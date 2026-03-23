defmodule Example.Loaders.ProductLoader do
  @behaviour AshIntegration.OutboundIntegrations.Loader

  @impl true
  def load_event(resource_id, action, _schema_version, _actor, occurred_at) do
    {:ok,
     %{
       resource: "product",
       action: to_string(action),
       schema_version: 1,
       occurred_at: DateTime.to_iso8601(occurred_at),
       data: %{id: resource_id}
     }}
  end

  @impl true
  def sample_resource_id(_actor, _action) do
    {:error, :no_sample_resource}
  end
end
