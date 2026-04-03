defmodule AshIntegration.Test.Parent do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntegration.Test.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :public_child, AshIntegration.Test.PublicChild, public?: true
    belongs_to :restricted_child, AshIntegration.Test.RestrictedChild, public?: true
    belongs_to :filtered_child, AshIntegration.Test.FilteredByOwner, public?: true
    has_many :public_items, AshIntegration.Test.NestedPublic, public?: true
    has_many :accessing_from_child, AshIntegration.Test.AccessingFromOnly, public?: true
    belongs_to :no_auth_child, AshIntegration.Test.NoAuthorizerChild, public?: true
  end

  actions do
    defaults [:read]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshIntegration.Test.PublicChild do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntegration.Test.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_v7_primary_key :id
    attribute :value, :string, public?: true
  end

  relationships do
    belongs_to :nested_restricted, AshIntegration.Test.RestrictedChild, public?: true
  end

  actions do
    defaults [:read]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshIntegration.Test.RestrictedChild do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntegration.Test.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_v7_primary_key :id
    attribute :secret, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(^actor(:role) == :admin)
    end
  end
end

defmodule AshIntegration.Test.NestedPublic do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntegration.Test.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_v7_primary_key :id
    attribute :label, :string, public?: true
  end

  relationships do
    belongs_to :parent, AshIntegration.Test.Parent, public?: true
    belongs_to :restricted, AshIntegration.Test.RestrictedChild, public?: true
  end

  actions do
    defaults [:read]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshIntegration.Test.FilteredByOwner do
  @moduledoc false
  # This resource uses a data-dependent filter policy.
  # Ash.can? always returns true for these (it adds a query filter
  # instead of denying), but a non-owner should NOT see sample data.
  use Ash.Resource,
    domain: AshIntegration.Test.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, public?: true
    attribute :owner_id, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end
end

defmodule AshIntegration.Test.AccessingFromOnly do
  @moduledoc false
  # This resource is ONLY accessible through a relationship.
  # A standalone Ash.can? call has no accessing_from context,
  # so it always returns false — even when the actor CAN read
  # through the relationship.
  use Ash.Resource,
    domain: AshIntegration.Test.Domain,
    data_layer: Ash.DataLayer.Simple,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_v7_primary_key :id
    attribute :detail, :string, public?: true
  end

  relationships do
    belongs_to :parent, AshIntegration.Test.Parent, public?: true
  end

  actions do
    defaults [:read]
  end

  policies do
    policy always() do
      authorize_if accessing_from(AshIntegration.Test.Parent, :accessing_from_child)
    end
  end
end

defmodule AshIntegration.Test.NoAuthorizerChild do
  @moduledoc false
  # Ash resource WITHOUT authorizers configured.
  # Ash.can/3 may behave differently when no authorizer is present.
  use Ash.Resource,
    domain: AshIntegration.Test.Domain,
    data_layer: Ash.DataLayer.Simple

  attributes do
    uuid_v7_primary_key :id
    attribute :info, :string, public?: true
  end

  relationships do
    belongs_to :parent, AshIntegration.Test.Parent, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshIntegration.Test.EmbeddedAddress do
  @moduledoc false
  defstruct [:street, :city]
end
