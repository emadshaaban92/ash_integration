# WhatsApp Transport

The WhatsApp transport delivers events as WhatsApp messages over **Meta's
WhatsApp Business Cloud API** — an authenticated HTTPS POST of JSON to
`graph.facebook.com`. The connection carries the WhatsApp Business phone number
and access token; each subscription (or its Lua transform) supplies the
recipient and the message, and the event flows through the same outbound
pipeline as every other transport — capture, fan-out, transform, retry/backoff,
two-level suspension, and the dashboard.

Mechanically it is an HTTP cousin, but it is a **distinct transport** because the
message descriptor, config, and error semantics are domain-specific: modeling
WhatsApp into the raw HTTP transport would push all the Graph JSON shaping into
every host's Lua transform with no validation.

## Who configures it (and pays for it)

Like the HTTP, Kafka, and Email transports, the WhatsApp configuration lives **on
the connection**, not in the host application. The connection owner supplies their
own WhatsApp Business Account (WABA), phone number, and access token (encrypted at
rest), and sends — and pays Meta per conversation — under their own account. The
library provides the typed schema, validation, secret handling, and dashboard.

## No extra dependencies

The Cloud API is a plain authenticated HTTPS POST, issued with **Req** (already a
dependency). There is nothing optional to install, so the WhatsApp transport is
**always available** in the dashboard, exactly like HTTP.

## The dominant constraint: templates vs the 24-hour window

You cannot send arbitrary free-form text to a user at any time. Free-form
("session") text is only allowed inside a **24-hour customer-service window** that
opens when the *user* messages your business. System-initiated notifications —
this library's whole job — are almost always sent **outside** that window, so they
must use **pre-approved message templates** (a name + language + parameters).

So the primary message shape is a **template**, not text. Template creation and
approval happen in **Meta Business Manager** and are **out of scope** for this
library — it only references a template by name. A send that requires re-engagement
outside the window (Meta error `131047`) is classified as a non-retryable response
failure: the message needs a template, and retrying the same free-form text will
not succeed.

## Configuration

A connection holds the **WABA phone number and access token**, modeled as an
`adapter` union so a second provider can be added later (see *A second provider*
below). Set the connection's `transport_config.type` to `:whatsapp`:

```elixir
%{
  type: :whatsapp,
  adapter: %{
    type: "meta_cloud",
    phone_number_id: "123456789012345",   # Required — the WhatsApp Business phone number ID (digits only)
    access_token: "EAAG…",                 # Required on create — encrypted at rest (AshCloak)
    api_version: "v21.0",                  # Defaults to v21.0 — must be `v<major>.<minor>`
    business_account_id: "998877665544"    # Optional
  }
}
```

The endpoint is derived as:

```
POST https://graph.facebook.com/<api_version>/<phone_number_id>/messages
Authorization: Bearer <access_token>
Content-Type: application/json
```

Pick a recent `api_version` (Meta ships a new one regularly and deprecates old
ones — verify the current version against Meta's docs). Both `phone_number_id`
(bare digits) and `api_version` (`v<major>.<minor>`) are validated on save — they
are interpolated into the Graph URL, so a stray space or CR/LF is rejected as a
field error at save rather than crashing the send. The `access_token` is
encrypted at rest exactly like an HTTP bearer token, a Kafka SASL password, or an
SMTP password, and is decrypted **live at delivery** — never stored in the wire
descriptor, never logged, and a rotated token takes effect immediately.

## Recipient and template defaults (per subscription)

The recipient and default template a delivery uses come from the subscription's
`route_config` (a transport-tagged union mirroring the connection's
`transport_config`), or from the Lua transform. All fields are optional:

```elixir
route_config: %{
  type: :whatsapp,
  to: "15551234567",          # Optional default recipient (E.164 digits)
  template_name: "order_shipped",
  language: "en_US"
}
```

## Rendering the message in the transform

The transform mutates the pre-seeded `defaults`. The ergonomic path for a template
sets `to`, `type = "template"`, and a `template` table with a `body_params` list
that is expanded into the Graph `components` array for you:

```lua
function transform(event, defaults)
  defaults.to = event.data.phone
  defaults.type = "template"
  defaults.template = { name = "order_shipped", language = "en_US",
                        body_params = { event.data.order_id, event.data.tracking } }
  return defaults
end
```

For header/button/media components, supply a raw `components` array instead of
`body_params` — it passes through untouched (the escape hatch):

```lua
defaults.template = {
  name = "receipt", language = "en_US",
  components = {
    { type = "button", sub_type = "url", index = "0",
      parameters = { { type = "text", text = event.data.token } } }
  }
}
```

A **text (session)** message — only deliverable inside the 24-hour window — sets
`type = "text"` and a `text` body:

```lua
function transform(event, defaults)
  defaults.to = event.data.phone
  defaults.type = "text"
  defaults.text = "Your code is " .. event.data.code
  return defaults
end
```

### Validation (parks on a bad descriptor)

At dispatch the resolver validates and, on failure, **parks** the delivery with a
clear error rather than sending something malformed:

- **`to`** must be present and look like an E.164 phone number. A leading `+` is
  stripped; anything with non-digits (control chars included) parks.
- **`type == "template"`** requires a template `name` and `language`.
- **`type == "text"`** requires a non-empty `text` body.

## Message Format

The stored descriptor is **semantic** (transform-shaped); the transport shapes the
Graph JSON at send time. A text message:

```json
{ "messaging_product": "whatsapp", "recipient_type": "individual",
  "to": "15551234567", "type": "text",
  "text": { "preview_url": false, "body": "message text" } }
```

A template message:

```json
{ "messaging_product": "whatsapp", "to": "15551234567", "type": "template",
  "template": { "name": "order_shipped", "language": { "code": "en_US" },
    "components": [ { "type": "body", "parameters": [
      { "type": "text", "text": "John" }, { "type": "text", "text": "12345" } ] } ] } }
```

## Accepted ≠ delivered

A **200** from the Cloud API means Meta **accepted** the message for sending — not
that it was delivered to or read by the recipient. The success metadata is the
returned `wamid` message id (`messages[0].id`). True delivered/read status arrives
later via **inbound webhooks**, which this *outbound* library does not handle; a
host that needs delivery receipts consumes those webhooks separately.

## Delivery, retries, and suspension

A non-2xx is classified on Meta's `error.code` (**verify against Meta's docs — the
codes evolve**) and mapped onto the two-level suspension model:

| Code / condition | failure_class | retryable | Meaning |
|---|---|---|---|
| HTTP 5xx (unclassified) | `:transport` | yes | Meta-side hiccup |
| 429 / 130429 / 80007 / 131056 | `:transport` | yes (honors `Retry-After`) | Rate / pair-rate limit |
| 190 | `:transport` | no | Access token expired/invalid → suspend the connection |
| 368 | `:transport` | no | Temporarily blocked (policy) |
| 131026 | `:response` | no | Undeliverable (recipient not on WhatsApp) |
| 131047 | `:response` | no | Re-engagement / outside 24h window → needs a template |
| 131051 | `:response` | no | Unsupported message type |
| 132000–132016 | `:response` | no | Template errors (not found/not approved/param mismatch/paused/…) |
| 100 | `:response` | no | Invalid parameter |
| unknown | `:transport` | yes | Mirrors the HTTP transport's network-error default |

- A **transport** failure (rate limit, expired token, policy block, unreachable
  host) counts against the **connection** and can auto-suspend it.
- A **response** failure (undeliverable recipient, template problem, invalid
  parameter) suspends just the **subscription** — the payload is wrong, not the
  connection.
- On a retryable rate limit, Meta's `Retry-After` header overrides the exponential
  backoff (clamped, so a hostile header can't park a lane).

A successful send resets the relevant counter.

## Payload Signing

The WhatsApp transport does not carry a payload-signing scheme — the receiving end
is Meta's API, not a consumer verifying an HMAC. The `signing` configuration and
dashboard card are therefore not shown for WhatsApp connections (as for email).

## A second provider (future)

The provider is modeled as an `adapter` union — `meta_cloud` today — exactly like
the email transport's SMTP-vs-API split, leaving room for a **Twilio** WhatsApp
adapter later. Twilio's WhatsApp API is shaped differently (`From`/`To`/`Body`, or
a `ContentSid` + variables, over Basic auth), so it would land as a new adapter
variant behind the same `:whatsapp` transport — a config choice, not a code fork.
It is noted here but **not built**.
