defmodule Example.Catalog do
  use Ash.Domain

  resources do
    resource Example.Catalog.Product
    resource Example.Catalog.Widget
    resource Example.Catalog.StockItem
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
