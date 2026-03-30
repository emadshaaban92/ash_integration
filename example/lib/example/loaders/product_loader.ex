defmodule Example.Loaders.ProductLoader do
  @behaviour AshIntegration.OutboundIntegrations.Loader

  @impl true
  def load_event(resource_id, action, 1 = _schema_version, actor, occurred_at) do
    case Ash.get(Example.Catalog.Product, resource_id, actor: actor) do
      {:ok, product} ->
        {:ok,
         %{
           resource: "product",
           action: to_string(action),
           schema_version: 1,
           occurred_at: DateTime.to_iso8601(occurred_at),
           data: %{
             id: product.id,
             name: product.name,
             sku: product.sku
           }
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
  def sample_event(1) do
    %{
      resource: "product",
      action: "create",
      schema_version: 1,
      occurred_at: "2024-01-15T10:30:00Z",
      data: %{
        id: "00000000-0000-0000-0000-000000000000",
        name: "Example Product",
        sku: "SKU-001"
      }
    }
  end
end
