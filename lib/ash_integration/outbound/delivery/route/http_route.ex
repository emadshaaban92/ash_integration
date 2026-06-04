defmodule AshIntegration.Outbound.Delivery.Route.HttpRoute do
  @moduledoc """
  The per-subscription HTTP route. The connection owns the base URL, auth, and a
  default timeout; this owns where/how *this* event type is delivered on top of
  it. All fields are optional — a route with everything unset POSTs to the
  connection's base URL with the default timeout.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    # Joined onto the connection's base_url; nil/blank → the base URL itself.
    attribute :path, :string, public?: true

    attribute :method, :atom do
      public? true
      constraints one_of: [:post, :put, :patch, :delete]
    end

    # Overrides the connection's default request timeout when set.
    attribute :timeout_ms, :integer do
      public? true
      constraints min: 1000
    end
  end

  validations do
    validate {AshIntegration.Transport.Validations.HttpTimeout, []}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
