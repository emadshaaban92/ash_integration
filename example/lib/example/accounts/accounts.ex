defmodule Example.Accounts do
  use Ash.Domain

  resources do
    resource Example.Accounts.User
    resource Example.Accounts.Token
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
