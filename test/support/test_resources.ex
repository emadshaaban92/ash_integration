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
    has_many :public_items, AshIntegration.Test.NestedPublic, public?: true
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

defmodule AshIntegration.Test.EmbeddedAddress do
  @moduledoc false
  defstruct [:street, :city]
end
