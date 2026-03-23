defmodule Example.Catalog do
  use Ash.Domain

  resources do
    resource Example.Catalog.Product
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
