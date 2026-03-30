defmodule Example.Loaders.ProductLoader do
  @behaviour AshIntegration.OutboundIntegrations.Loader

  @impl true
  def load_event_data(resource_id, _action, 1 = _schema_version, actor) do
    case Ash.get(Example.Catalog.Product, resource_id, actor: actor) do
      {:ok, product} ->
        {:ok,
         %{
           id: product.id,
           name: product.name,
           sku: product.sku
         }}

      {:error, _} ->
        {:error, "Product not found"}
    end
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

  @impl true
  def sample_event_data(1) do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      name: "Example Product",
      sku: "SKU-001"
    }
  end
end
