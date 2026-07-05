# Email Transport

The email transport delivers events as email, over SMTP. It builds on
[Swoosh](https://hex.pm/packages/swoosh): the connection carries the sender
identity and the SMTP server, each subscription (or its Lua transform) supplies
the recipients, subject, and body, and the event flows through the same outbound
pipeline as every other transport — capture, fan-out, transform, retry/backoff,
two-level suspension, and the dashboard.

## Who configures it (and pays for it)

Like the HTTP and Kafka transports, the email configuration lives **on the
connection**, not in the host application. The connection owner supplies their
own SMTP server and credentials (encrypted at rest), and sends — and pays —
under their own account. The library provides the typed schema, validation,
secret handling, and dashboard; the host app doesn't wire in a global mailer.

## Why SMTP first

Every provider — Amazon SES, SendGrid, Postmark, Mailgun, Gmail, Office 365, an
internal Postfix relay — exposes an SMTP endpoint. So a single SMTP adapter
already lets a connection target essentially any provider (point `relay` at
`smtp.sendgrid.net`, `username` `apikey`, and the password at the API key, for
example). Because it builds on Swoosh, native provider-API adapters (the SES or
SendGrid HTTP APIs) can be added later as new `adapter` variants behind the same
`:email` transport — a config choice, not a code fork.

## Prerequisites

The email transport requires **Swoosh** and **gen_smtp**. Add them to your
`mix.exs`:

```elixir
{:swoosh, "~> 1.0"},
{:gen_smtp, "~> 1.0"}
```

Swoosh only needs an HTTP API client for its *API* adapters (including the
Microsoft Graph app-only adapter below); the SMTP adapter does not. This library
uses **Req** — already a dependency — as the client, and the SMTP path ignores
it, so a single setting serves both:

```elixir
# config/config.exs
config :swoosh, :api_client, Swoosh.ApiClient.Req
```

A host that only ever uses SMTP can set this back to `false` to skip the API
client entirely.

The transport appears in the dashboard automatically once both dependencies are
available.

## Configuration

A connection holds the **sender identity and the SMTP server**. Set the
connection's `transport_config.type` to `:email`:

```elixir
%{
  type: :email,
  from: "Acme Notifications <notifications@acme.com>",  # Default sender (transform may override)
  adapter: %{
    type: "smtp",
    relay: "smtp.acme.com",       # Required — the SMTP host
    port: 587,                     # Defaults to 587
    username: "apikey",            # Optional — omit for an open/internal relay
    password: "super-secret",      # Optional — encrypted at rest (AshCloak)
    ssl: false,                    # Implicit TLS on connect (SMTPS, usually port 465)
    tls: :if_available,            # STARTTLS: :if_available (default), :always, :never
    auth: :if_available,           # SMTP AUTH: :if_available (default), :always, :never
    verify: :verify_peer,          # Certificate verification (default; see TLS below)
    cacert_pem: nil                # Optional inline PEM cert for a private CA
  },
  headers: %{                      # Optional static email headers
    "x-source" => "my-app"
  }
}
```

`from` accepts a bare address (`bot@acme.com`) or a display-name form
(`Acme <bot@acme.com>`), which is split into a proper `From` header. The address
part must be a plausible mailbox — spaces, control characters, and the URL
metacharacters `/`, `?`, and `#` are rejected, since the address can flow into the
Microsoft Graph `sendMail` URL.

The SMTP `password` is encrypted at rest exactly like an HTTP bearer token or a
Kafka SASL password, and is decrypted **live at delivery** — never stored in the
delivery descriptor, and a rotated password takes effect immediately.

## Microsoft Graph (Office 365) — app-only OAuth2

For Office 365 / Microsoft 365, the **app-only** (consent-free) target is an
Azure app registration with the **`Mail.Send` application permission + admin
consent**, sending through the Graph `sendMail` endpoint as a configured
user/shared mailbox. This is the recommended OAuth2 email path: it uses the same
two-legged **client-credentials** grant as the HTTP transport (no browser
consent, no refresh tokens, no per-user delegation) and Swoosh's
`Swoosh.Adapters.MsGraph` adapter does the sending.

Set the adapter `type` to `ms_graph`. The OAuth2 block is the **same shared
client-credentials schema** the HTTP transport uses:

```elixir
%{
  type: :email,
  from: "notifications@acme.com",       # the sending mailbox (unless user_id overrides)
  adapter: %{
    type: "ms_graph",
    user_id: nil,                        # optional: send as a specific user/shared mailbox id
    oauth2: %{
      token_url: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
      client_id: "{application-client-id}",
      client_secret: "{client-secret}",  # encrypted at rest (AshCloak), required
      scopes: "https://graph.microsoft.com/.default",
      auth_style: :post                  # :post (default) or :basic
    }
  }
}
```

Azure setup (once, by a tenant admin):

1. Register an application in Entra ID (Azure AD); note the **Application (client)
   ID** and **Directory (tenant) ID**.
2. Add a client secret; use it as `client_secret`.
3. Under **API permissions**, add the **Application** permission
   `Microsoft Graph → Mail.Send`, then **Grant admin consent**.
4. `token_url` is
   `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token`, and `scopes`
   is `https://graph.microsoft.com/.default` (the client-credentials flow uses
   the app's consented permissions, so `.default` is correct — not per-request
   scopes).

The access token is fetched live, cached, and single-flighted by the shared
token provider exactly as for HTTP (see the HTTP transport guide's OAuth2
section). The `client_secret` is encrypted at rest and never logged. If
`user_id` is set, the send targets `/users/{user_id}/sendMail` (a specific
user/shared mailbox); otherwise the mailbox is derived from the `from` address.
Either way the mailbox is validated (no spaces, control chars, or `/ ? #`) and
percent-encoded into the request path, so it can never rewrite the Graph endpoint.

> Requires `config :swoosh, :api_client, Swoosh.ApiClient.Req` (see
> Prerequisites) — the Graph adapter sends over HTTP.

## Provider API-key adapters (the simpler alternative)

If you don't specifically need OAuth2, most providers offer a plain **API-key**
HTTP adapter that needs no OAuth at all — Swoosh ships adapters for SendGrid,
Mailgun, Postmark, Amazon SES, Brevo, Resend, Mailjet, and more. These are often
the simplest option: set `config :swoosh, :api_client, Swoosh.ApiClient.Req` and
add a new `adapter` variant wrapping the provider's adapter + its API key
(encrypted at rest like the SMTP password). Only Microsoft Graph is shipped as a
first-class OAuth2 adapter today because app-only Graph is the clean,
consent-free path for Office 365.

## SMTP XOAUTH2 (not shipped)

Provider-agnostic **SMTP OAuth2** (feeding the client-credentials access token as
an `AUTH XOAUTH2` credential) is mechanically possible — `gen_smtp` implements
the `XOAUTH2` mechanism — but is **not** shipped. Swoosh's `Swoosh.Adapters.SMTP`
does not expose a clean seam to force the XOAUTH2 mechanism or pass a
short-lived, per-send token as the credential, and app-only SMTP OAuth is
historically limited on the major providers. Microsoft Graph app-only (above) is
the recommended OAuth2 email path; SMTP XOAUTH2 remains a possible future
follow-up if a provider-agnostic need arises.

## TLS and certificate verification

**Certificate verification is on by default.** Whenever a delivery negotiates
TLS — implicit SSL (`ssl: true`) or a STARTTLS upgrade (`tls: :always` /
`:if_available`) — the relay's certificate chain **and** hostname are verified
against the OS trust store before any mail is sent. This is the secure default;
no configuration is needed.

Two fields tune verification:

| Field        | Default        | Purpose                                                        |
| ------------ | -------------- | ------------------------------------------------------------- |
| `verify`     | `:verify_peer` | `:verify_peer` checks chain + hostname; `:verify_none` disables checking |
| `cacert_pem` | `nil`          | Inline PEM certificate for a private CA; **augments** the OS trust store when set |

**Opting a specific internal relay out.** An internal relay with a self-signed
or absent certificate can turn verification off — but only for that one
connection, as a stored, visible choice:

```elixir
adapter: %{type: "smtp", relay: "internal-relay.corp", verify: :verify_none, ...}
```

There is no global switch that disables verification everywhere.

> **Hostname check.** Because the default verifies the hostname, a relay reached
> by IP address, or by a name not listed in the certificate's SAN, fails the
> handshake. This is inherent to real verification — fix it at the source (issue
> the cert with the right SANs) or, for a relay that genuinely can't present a
> matching cert, opt that one connection out with `verify: :verify_none`.

**Trusting a private CA.** When the relay's certificate is signed by an internal
CA, keep verification on and paste the CA's PEM certificate directly onto the
connection via `cacert_pem`. It is stored on the connection record itself — no
side-channel file to place on every node — and **augments** the OS trust store,
so the same connection can still reach public-CA relays:

```elixir
adapter: %{
  type: "smtp",
  relay: "mail.corp",
  cacert_pem: "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
  ...
}
```

A `cacert_pem` that contains no decodable certificate is rejected at delivery as
a non-retryable transport error rather than silently trusting nothing.

### STARTTLS downgrade caveat (`tls: :if_available`)

`tls: :if_available` (the default) upgrades to TLS **only if** the relay
advertises STARTTLS. An active network attacker can **strip** that advertisement
and keep the session in plaintext — the connection silently falls back rather
than failing. This is intentionally tolerated because many internal plaintext
relays rely on it.

For an **internet-facing relay, set `tls: :always`** so a stripped STARTTLS
offer aborts delivery instead of leaking mail over plaintext. When a delivery
uses `:if_available` against a non-internal (non-RFC1918/loopback) relay, the
library logs a one-time warning recommending `:always`.

## Recipients and subject (per subscription)

The recipients and subject a delivery uses come from the subscription's
`route_config` (a transport-tagged union mirroring the connection's
`transport_config`), or from the Lua transform. All fields are optional:

```elixir
route_config: %{
  type: :email,
  to: ["ops@acme.com"],
  cc: ["lead@acme.com"],
  subject: "Stock changed"
}
```

## Rendering the email in the transform

Email is human-facing, so the body (and usually the recipients and subject) is
rendered per event by the Lua transform, which mutates the pre-seeded
`defaults`:

```lua
function transform(event, defaults)
  defaults.to = { "ops@acme.com", event.data.owner_email }
  defaults.subject = "Order " .. event.data.id .. " shipped"
  defaults.html = "<h1>Shipped</h1><p>Order " .. event.data.id .. " is on its way.</p>"
  defaults.text = "Order " .. event.data.id .. " is on its way."
  return defaults
end
```

A delivery must resolve to **at least one `to` recipient, a subject, and at
least one body** (`html` or `text`). If any is missing, the delivery parks with a
clear error rather than sending a malformed message.

## Message Format

The resolved `defaults` for the route are replayed verbatim into the message:

- **from** — `defaults.from` (defaults to the connection's `from`)
- **to / cc / bcc** — `defaults.to` / `defaults.cc` / `defaults.bcc` (a string or
  a list of address strings)
- **subject** — `defaults.subject`
- **html / text** — `defaults.html` and/or `defaults.text` (at least one required)
- **headers** — `x-`-prefixed wire metadata, plus any static/transform headers:
  - `x-event-id` — the event's UUIDv7 (use it to deduplicate)
  - `x-event-type` — the event type, e.g. `order.shipped`
  - `x-event-version` — the schema version
  - `content-type` — `application/json` seed (overridable)
  - Any custom headers from config (lowest priority — cannot shadow the above)

All recipients, the subject, and header values pre-seed the transform's
`defaults`, so a subscription can override or remove any of them.

### Header-injection safety

Because a transform can build recipients and the subject from untrusted event
data, a raw CR/LF there is an SMTP header-injection vector. Any control character
(`CR`/`LF`/etc.) in an address, a recipient, or the subject **parks the delivery**
at the resolver boundary instead of reaching the wire.

## Delivery, retries, and suspension

Swoosh's SMTP adapter (gen_smtp) opens a connection per send, so the transport is
stateless in the relay — there is no persistent client to manage. Failures map
onto the two-level suspension model using gen_smtp's own permanent/temporary
distinction:

- **Permanent SMTP rejection** (a 5xx reply — bad recipient, rejected content) →
  a **response** failure that is **not retried**: the target rejected *this*
  message, so the **subscription** is suspended.
- **Temporary SMTP failure** (a 4xx reply — greylisting, rate limit) → a
  **response** failure that **is retried** later.
- **Connection-level failure** (the relay is unreachable — refused, timeout, DNS)
  → a **transport** failure that **is retried**; persistent failures count
  against the **connection** and can auto-suspend it (pausing all its
  subscriptions).
- **Credential/auth failure** → a non-retryable **transport** failure (it won't
  fix itself on retry), surfacing quickly so the connection suspends.

A successful send resets the relevant counter.

## Payload Signing

The email transport does not carry a payload-signing scheme — unlike a webhook or
a Kafka record, a notification email has no downstream consumer that verifies an
HMAC. The `signing` configuration and dashboard card are therefore not shown for
email connections.
