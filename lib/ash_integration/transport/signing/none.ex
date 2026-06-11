defmodule AshIntegration.Transport.Signing.None do
  @moduledoc """
  The `none` signing scheme — the delivery is sent unsigned.

  Carries no secret field, so "a secret with no scheme" / "a scheme with no
  secret" are unrepresentable. This is the default variant of the `signing` union.
  """
  use Ash.Resource,
    data_layer: :embedded

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
