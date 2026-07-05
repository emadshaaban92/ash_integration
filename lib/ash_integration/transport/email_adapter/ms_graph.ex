defmodule AshIntegration.Transport.EmailAdapter.MsGraph do
  @moduledoc """
  Microsoft Graph (Office 365) **app-only** email adapter config.

  This is the consent-free email target: an Azure app registration with the
  `Mail.Send` **application** permission + admin consent sends mail via the Graph
  `sendMail` endpoint as a configured user/shared mailbox — no per-user OAuth
  consent, no delegation. It reuses the shared client-credentials token provider
  (`AshIntegration.Transport.OAuth2`); `Swoosh.Adapters.MsGraph` does the sending.

  The OAuth2 config (including the encrypted `client_secret`) is the same
  `ClientCredentials` embedded resource the HTTP transport uses — HTTP and Email
  share one schema and one token cache rather than forking it.
  """
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    # The client-credentials grant used to obtain a Graph access token. The
    # `scopes` are typically "https://graph.microsoft.com/.default".
    attribute :oauth2, AshIntegration.Transport.OAuth2.ClientCredentials do
      allow_nil? false
      public? true
    end

    # Optional sending mailbox override. Graph's `sendMail` sends as
    # `/users/{id}/sendMail`; by default that mailbox is derived from the message
    # `from` address. Set this to send from a specific user/shared mailbox id
    # different from the From header (Swoosh's MsGraph `:url` seam).
    attribute :user_id, :string do
      allow_nil? true
      public? true
    end
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
