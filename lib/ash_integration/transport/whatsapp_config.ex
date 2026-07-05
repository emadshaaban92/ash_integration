defmodule AshIntegration.Transport.WhatsAppConfig do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    # The provider adapter. A tagged union so a second provider (Twilio's WhatsApp
    # API, which uses From/To/Body or a ContentSid + variables over Basic auth) can
    # be added as a variant later without reshaping stored config — mirroring how
    # `EmailConfig.adapter` nests SMTP-vs-provider-API. v1 ships Meta's WhatsApp
    # Business Cloud API adapter only.
    attribute :adapter, :union do
      allow_nil? false
      public? true

      constraints types: [
                    meta_cloud: [
                      type: AshIntegration.Transport.WhatsAppAdapter.MetaCloud,
                      tag: :type,
                      tag_value: "meta_cloud"
                    ]
                  ],
                  storage: :map_with_tag
    end
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
