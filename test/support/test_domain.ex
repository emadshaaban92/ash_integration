defmodule AshIntegration.Test.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshIntegration.Test.Parent
    resource AshIntegration.Test.PublicChild
    resource AshIntegration.Test.RestrictedChild
    resource AshIntegration.Test.NestedPublic
  end
end
