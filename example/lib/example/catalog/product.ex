defmodule Example.Catalog.Product do
  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Inbound.Declare.Commands],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "products"
    repo Example.Repo
  end

  inbound_commands do
    command "record_partner_ref" do
      action :record_partner_ref
      handler(Example.Inbound.RecordPartnerRef)
    end
  end

  actions do
    default_accept [:name, :sku]
    defaults [:read, create: :*]

    update :update do
      accept [:name, :sku]
      require_atomic? false
    end

    update :record_partner_ref do
      accept [:partner_ref]
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
    attribute :partner_ref, :string, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
