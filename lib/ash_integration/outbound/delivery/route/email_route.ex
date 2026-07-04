defmodule AshIntegration.Outbound.Delivery.Route.EmailRoute do
  @moduledoc """
  The per-subscription email route. The connection owns the sender identity and
  the SMTP server; this owns the default recipients and subject for *this* event
  type. All fields are optional — the Lua transform typically renders recipients,
  subject, and body from the event data, and these are the fallbacks it starts
  from.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    # Default recipients. The transform can override or extend them per event.
    attribute :to, {:array, :string}, public?: true
    attribute :cc, {:array, :string}, public?: true

    # Default subject line; usually rendered per event by the transform.
    attribute :subject, :string, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
