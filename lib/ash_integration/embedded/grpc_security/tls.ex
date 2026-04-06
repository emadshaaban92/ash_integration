defmodule AshIntegration.GrpcSecurity.Tls do
  use Ash.Resource,
    data_layer: :embedded

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
