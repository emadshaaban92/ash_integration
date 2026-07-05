# HTTP Transport

The HTTP transport delivers JSON payloads to external endpoints via HTTP requests. This is the simplest transport and a good starting point.

## Configuration

A connection holds the **base URL, auth, signing scheme, and a default timeout** — the shared "who and how to authenticate." Each subscription under it sets its own **route** (request path + HTTP method). Set the connection's `transport_config.type` to `:http`:

```elixir
%{
  type: :http,
  base_url: "https://api.example.com",  # scheme + host (+ optional base path)
  timeout_ms: 30_000,      # Default request timeout in ms (default: 30s, min: 1s)
  auth: %{type: "none"},   # See Authentication below
  headers: %{              # Optional connection-wide custom headers
    "x-source" => "my-app"
  },
  signing: %{type: "none"} # Explicit signing scheme — see Payload Signing
}
```

The maximum allowed `timeout_ms` is configurable via the `:http_max_timeout_ms` setting (default: 60s).

### Per-subscription route

Each subscription chooses where its event type lands and how:

| Subscription field | Meaning |
|--------------------|---------|
| `path` | Joined onto the connection's `base_url`. Leave blank to deliver to the base URL itself (single-endpoint webhooks). |
| `method` | `:post` (default), `:put`, `:patch`, or `:delete`. |
| `timeout_ms` | Optional override of the connection's default timeout. |

These live in the subscription's `route_config` — a transport-tagged union mirroring the connection's `transport_config`, so new transports add a variant rather than new fields:

```elixir
route_config: %{type: :http, path: "/products", method: :put}
```

So `product.created` can `POST /products` while `inventory.adjusted` does `PUT /inventory` — different paths and verbs, both over **one** connection (one set of credentials, one ordering domain). A consumer with a single ingest endpoint just leaves `route_config` unset (or `path` blank) on every subscription.

> **`route_config` is the static default** for the route. For a **per-event** path or a fully different destination, the Lua transform can set `defaults.path` (joined onto `base_url`) or `defaults.url` (a full absolute override) — e.g. `function transform(event, defaults) defaults.path = "/products/" .. event.data.id return defaults end`. See [Lua transform scripts](../README.md#lua-transform-scripts).

## Authentication

The `auth` field (inside `transport_config`) supports five strategies:

### None (default)

```elixir
auth: %{type: "none"}
```

### Bearer Token

Adds an `Authorization: Bearer <token>` header.

```elixir
auth: %{type: "bearer_token", token: "sk-live-abc123"}
```

### API Key

Adds a custom header with the key value.

```elixir
auth: %{type: "api_key", header_name: "X-API-Key", value: "my-api-key"}
```

### Basic Auth

Adds an `Authorization: Basic <base64>` header.

```elixir
auth: %{type: "basic_auth", username: "user", password: "secret"}
```

### OAuth2 (client-credentials)

Fetches an access token from an OAuth2 **token endpoint** using the two-legged,
machine-to-machine **client-credentials** grant, and sends it as
`Authorization: Bearer <token>`. Only the app-only client-credentials grant is
supported — there is **no** authorization-code/consent flow, no refresh tokens,
and no per-user delegation.

```elixir
auth: %{
  type: "oauth2_client_credentials",
  token_url: "https://login.example.com/oauth2/token",
  client_id: "my-client-id",
  client_secret: "my-client-secret",   # encrypted at rest, required
  scopes: "https://api.example.com/.default",  # space-delimited, optional
  audience: "https://api.example.com",         # optional
  auth_style: :post                            # :post (default) or :basic
}
```

* `auth_style: :post` sends `client_id`/`client_secret` in the request body
  (`client_secret_post`); `:basic` sends them as an HTTP Basic `Authorization`
  header on the token request (`client_secret_basic`).
* The token is fetched **live at delivery** and **cached** until a refresh skew
  (default 60s) before its `expires_in` expiry. Many concurrent deliveries for
  the same connection coalesce to a **single** token fetch (single-flight), so a
  busy connection does not hammer the token endpoint. A rotated `client_secret`
  invalidates the cached token automatically.
* Token-endpoint failures are classified onto the delivery contract: a network
  error or a transient `5xx`/`429` is retryable; a `400`/`401`
  (bad/rotated/misconfigured credentials) is non-retryable and drives
  suspension. The token and the client secret are never logged and never written
  into the stored delivery descriptor.
* The `token_url` is run through the same SSRF egress guard as delivery URLs — at
  save (rejecting a private/loopback/metadata host) and again, pinned, at fetch.
* **Refresh-on-401** against the target (invalidate the cached token and retry
  once when the *target* returns 401) is a planned follow-up — today a token is
  refreshed purely on the expiry clock.

All auth credentials are encrypted at rest via AshCloak.

## Wire Contract

Each request leads with the event type. The body is the resolved
`defaults.body` (`Content-Type: application/json` by default), and the event
metadata travels in `x-`-prefixed headers:

> **Empty body.** An empty `defaults.body` — `nil`, or an empty Lua table (Lua
> can't distinguish `{}` from `[]`) — is sent as **no body** (no `Content-Type`
> on the wire). A consequence: you cannot emit a literal empty JSON object/array
> (`{}`/`[]`) as the body; wrap it in a field (e.g. `defaults.body = { data = {} }`)
> if a consumer requires one.

| Header | Value |
|--------|-------|
| `x-event-id` | The event's UUIDv7 (use it to deduplicate) |
| `x-event-type` | The event type, e.g. `product.created` |
| `x-event-version` | The schema version, e.g. `1` |
| `x-created-at` | ISO8601 timestamp of the event |
| `x-event-key` | The ordering/coalescing key (interpret it alongside `x-connection-id`) |
| `x-connection-id` | The connection's id |
| signature header(s) | Per the connection's `signing` scheme (see below) — e.g. `stripe-signature` for the `stripe` scheme |

These wire headers pre-seed the transform's `defaults.headers`, so a subscription
can override or remove any of them (including `x-event-id`). The connection's
static headers are merged in at lowest priority, so they can never shadow or
duplicate a wire header by default. `Authorization` is the exception — it's
injected live at delivery from the encrypted connection and never appears in the
stored descriptor, though a transform-set `authorization` header wins.

For recency, compare by `x-event-id`: the event id is a UUIDv7 generated in the
source transaction, so it is occurrence-ordered and breaks same-instant ties on
its own — last-write-wins by `x-event-id` directly. `x-created-at` is also on the
wire as a human-readable event timestamp, but the id is the ordering key. There
is no sequence number.

## Payload Signing

Whether (and how) a connection signs is an **explicit choice**: the
`transport_config.signing` field is a tagged union — the variant *is* the answer,
so there is no implicit "secret present ⇒ sign" switch.

### `none` (default)

```elixir
signing: %{type: "none"}
```

Deliveries are sent unsigned. This variant carries no secret field, so "a secret
with no scheme" is unrepresentable.

### `stripe`

The Stripe webhook format, built in natively (no sandbox):

```elixir
signing: %{type: "stripe", secret: "whsec_...", header_name: "stripe-signature"}
```

The body is signed with HMAC-SHA256 and sent in the configured header
(`header_name` defaults to `stripe-signature`; it is lowercased on the wire):

```
stripe-signature: t=1234567890,v1=abc123def456...
```

To verify on the receiving end:

1. Extract the timestamp (`t`) and signature (`v1`) from the header
2. Compute `HMAC-SHA256(secret, "#{timestamp}.#{raw_body}")`
3. Compare with `v1` (hex-encoded, lowercase)

### `custom`

A staged Lua signing behaviour for targets with novel schemes (canonical request
strings, embedded body signatures, presigned URLs). The script exposes optional
pure callbacks — `content(ctx)`, `string_to_sign(ctx)`, `headers(ctx)`,
`body(ctx)`, `url(ctx)` — and the library applies the cryptographic primitives
between them, so **the secret never enters the sandbox**:

```elixir
signing: %{
  type: "custom",
  secret: "...",
  source: """
  function string_to_sign(ctx)
    return ctx.method .. "\\n" .. ctx.path .. "\\n" .. ctx.now.iso8601 .. "\\n" .. ctx.digest
  end

  function headers(ctx)
    return { ["x-signature"] = ctx.signature, ["x-timestamp"] = ctx.now.iso8601 }
  end
  """,
  algorithm: :sha256,  # :sha256 (default) | :sha1 | :sha512
  encoding: :hex       # :hex (default) | :base64 | :base64url
}
```

Every callback receives a read-only `ctx` (method, url, path, host, headers,
the encoded `body` string, the structured `data`, and a frozen `now` in several
formats) plus the threaded results (`ctx.digest`, `ctx.signature`). If no `body`
callback is defined, the cached encoded body bytes are sent **verbatim** — the
exact bytes that were signed — so detached-signature schemes are byte-identical
by construction. A `body` callback re-encodes (for schemes that embed the
signature in the payload). One footgun to know: numbers in `ctx.data` are Lua
floats — format them explicitly (`string.format("%d", n)`) when building
canonical strings. See `design/configurable-signing.md` for the full model.

### Live signing (all schemes)

The signature is computed **live at delivery**, with a frozen send-time
timestamp shared by every callback in the attempt. Each delivery attempt is
signed fresh, so the timestamp always reflects the real send — if your receiver
enforces a timestamp **tolerance window** for replay protection, retries after
backoff still verify. Because signing is live, **rotating the secret takes
effect immediately** on already-dispatched events — no reprocess needed. The
signature is never persisted; the body it signs is, however, snapshotted at
dispatch, so the signed content is stable across retries.

## Error Handling

| Response | Behavior |
|----------|----------|
| 2xx | Success — event → `delivered`, logged as `:success` |
| 5xx | Retried (up to 20 attempts with exponential backoff) |
| 4xx | Not retried, logged as `:failed` |
| Network error | Retried |

Failures are classified to isolate the blast radius:

- A **response rejection** (any non-2xx status) counts against the
  **subscription**. After enough consecutive rejections the *subscription* is
  auto-suspended — other event types on the same connection keep flowing.
- A **network error** (connection refused, DNS/TLS, timeout) counts against the
  **connection**. After enough consecutive transport failures the *connection*
  is auto-suspended, pausing all of its subscriptions.

A successful delivery resets both counters. Suspended routes keep accumulating
events safely (latest-state per key) until an operator investigates and
un-suspends. See the [Delivery Pipeline guide](delivery-pipeline.md#suspension--failure-isolation) for the full model.

## SSRF egress control

A connection's `base_url` is shape-checked (`https?://…`) but not range-checked,
and a Lua transform can point `defaults.url` at an **arbitrary absolute URL**. Left
unguarded, an operator-authored transform could aim a delivery at a private,
loopback, or link-local address — the cloud-metadata endpoint
(`169.254.169.254`), `localhost`, or an in-cluster service — turning the delivery
pipeline into an SSRF primitive.

The egress guard resolves the host of the effective delivery URL (covering both
the `base_url`-joined path **and** a transform-set `defaults.url`) and **blocks**
it when any resolved address is private/loopback/link-local/metadata. It runs at
dispatch (a blocked URL **parks** the delivery with a readable error, so no
retries are wasted) and again at send time (a backstop against DNS rebinding).

**Blocking is on by default.** A trusted internal deployment — delivering to a
private mesh, a sidecar, or an in-cluster host — opts out, or carves out specific
hosts:

```elixir
config :ash_integration,
  egress: [
    block_private?: true,                  # default; set false to allow all egress
    allow_hosts: ["metadata.internal"]     # exact host allowlist (escape hatch)
  ]
```

`allow_hosts` matches the URL's host verbatim (case-insensitively) and skips the
IP check for that host only — prefer it over disabling the guard globally.

**Redirects are never followed.** Delivery requests set `redirect: false`: the
egress guard only validates the URL being sent, so following a `3xx` to a
different host would slip past it (a public endpoint redirecting to
`169.254.169.254`). A redirect from a webhook target is treated as a non-2xx
rejection, not a route to chase.

## Req Options

You can inject custom options into all HTTP requests (useful for testing):

```elixir
config :ash_integration, :req_options, [plug: {Req.Test, MyApp.WebhookStub}]
```

## OAuth2 token cache tuning

The OAuth2 client-credentials token cache is configured with these
compile-time keys (set them before compiling `ash_integration`):

```elixir
config :ash_integration,
  oauth2_refresh_skew_ms: 60_000,   # refresh a token this long before its expiry
  oauth2_idle_timeout_ms: 300_000,  # sweep expired/idle cache entries on this interval
  oauth2_req_options: [plug: {Req.Test, MyApp.OAuth2Stub}]  # extra Req options for token requests (testing)
```
