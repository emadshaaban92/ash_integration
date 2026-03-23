defmodule Example.Catalog.Product do
  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "products"
    repo Example.Repo
  end

  outbound_integrations do
    resource_identifier("product")
    loader(Example.Loaders.ProductLoader)
    supported_versions([1])

    outbound_action(:create)
    outbound_action(:update)
  end

  actions do
    default_accept [:name, :sku]
    defaults [:read, create: :*]

    update :update do
      accept [:name, :sku]
      require_atomic? false
    end

    destroy :destroy do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :sku, :string, allow_nil?: false, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
