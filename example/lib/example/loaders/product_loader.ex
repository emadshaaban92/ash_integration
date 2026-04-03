defmodule Example.Loaders.ProductLoader do
  @behaviour AshIntegration.OutboundIntegrations.Loader

  @impl true
  def load_resource(resource_id, 1 = _schema_version, actor) do
    Ash.get(Example.Catalog.Product, resource_id, actor: actor)
  end

  def load_resource(_resource_id, schema_version, _actor) do
    {:error, {:unsupported_schema_version, schema_version}}
  end

  @impl true
  def build_sample_resource(1 = _schema_version, _action) do
    %Example.Catalog.Product{
      id: "00000000-0000-0000-0000-000000000000",
      name: "Example Product",
      sku: "SKU-001"
    }
  end

  @impl true
  def transform_event_data(product, _action, 1 = _schema_version) do
    %{
      id: product.id,
      name: product.name,
      sku: product.sku
    }
  end

  @impl true
  def sample_resource_id(actor, _action) do
    case Example.Catalog.Product
         |> Ash.Query.limit(1)
         |> Ash.read(actor: actor) do
      {:ok, [product | _]} -> {:ok, product.id}
      _ -> {:error, "No products exist yet — create one first"}
    end
  end
end
