defmodule AshIntegration.Outbound.Delivery.Route.WhatsAppRoute do
  @moduledoc """
  The per-subscription WhatsApp route. The connection owns the WABA phone number
  and access token; this owns the defaults for *this* event type — an optional
  default recipient and the default template name + language.

  All fields are optional. WhatsApp notifications are system-initiated and almost
  always land **outside** the 24-hour customer-service window, so the primary
  shape is a pre-approved template: the Lua transform typically renders the
  recipient `to` and the template parameters from the event data, starting from
  the defaults here.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    # Optional default recipient in E.164 form ("15551234567"). The transform
    # usually sets this per event from the event data.
    attribute :to, :string, public?: true

    # Default pre-approved template name (created + approved in Meta Business
    # Manager, which is out of scope for this library — it only references the
    # template by name).
    attribute :template_name, :string, public?: true

    # Default template language/locale code, e.g. "en_US".
    attribute :language, :string, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
