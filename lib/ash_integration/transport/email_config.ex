defmodule AshIntegration.Transport.EmailConfig do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    # Connection-level sender identity. A plain address ("bot@acme.com") or a
    # display-name form ("Acme <bot@acme.com>"). The Lua transform may override it
    # per event (`result.from`); this is the default.
    attribute :from, :string do
      allow_nil? false
      public? true
    end

    # The delivery mechanism. A tagged union so a native provider API adapter
    # (SES, SendGrid, …) can be added as a variant later without reshaping stored
    # config — mirroring how `HttpConfig.auth` and `KafkaConfig.security` nest a
    # union. v1 ships the universal SMTP adapter only.
    attribute :adapter, :union do
      allow_nil? false
      public? true

      constraints types: [
                    smtp: [
                      type: AshIntegration.Transport.EmailAdapter.Smtp,
                      tag: :type,
                      tag_value: "smtp"
                    ],
                    ms_graph: [
                      type: AshIntegration.Transport.EmailAdapter.MsGraph,
                      tag: :type,
                      tag_value: "ms_graph"
                    ]
                  ],
                  storage: :map_with_tag
    end

    # Extra static email headers (X-*, List-Unsubscribe, …). Merged under the wire
    # metadata headers at dispatch, all transform-overridable.
    attribute :headers, :map do
      public? true
      default %{}
    end
  end

  changes do
    # Store header names lowercase so they can't collide case-insensitively with
    # the library's wire headers or a transform override at delivery.
    change AshIntegration.Transport.Changes.DowncaseHeaderKeys
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
