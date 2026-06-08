# Design: Configurable Request Signing

**Status:** Draft / proposal — for review before implementation
**Related:** `AshIntegration.Transport.Signing`, `AshIntegration.Outbound.Wire.Transports.Http`, `AshIntegration.Outbound.Delivery.Transform.Runtime` (+ `…Runtime.Lua`), `AshIntegration.Outbound.Delivery.Resolver`, `AshIntegration.Transport.HttpConfig`

> **Assumed vocabulary.** Uses the outbound pipeline's existing terms — *dispatch
> time* vs *send time*, the *snapshot* (`event.delivery`), *reprocess*, *park*, and
> the `failure_class: :transport | :response` taxonomy. See
> `design/outbound-architecture.md`. A signing secret is `ash_cloak`-encrypted at
> rest; the transform sandbox is luerl-backed and has no clock or crypto (`os`/`io`
> are blocked).

## 1. Problem

Signing is hardcoded to one scheme in `Transport.Signing.signature/2` — Stripe's
webhook style (`"<unix_seconds>.<body>"` → `t=<ts>,v1=<hex>`, one `x-signature`
header, HMAC-SHA256 lowercase hex) — turned on implicitly whenever a
`signing_secret` is present. A connection gets *that* or nothing, and "secret
present" as the on-switch is ambiguous (a blank secret, a secret with no scheme).

The motivating target, the **Acumatica Bridge** Integrator API, signs differently
on every axis (canonical request string `METHOD\nPATH?query\nISO-8601\nSHA256_hex(body)`,
body pre-hashed, ISO-8601 timestamp, bare hex, **two** headers `X-Signature` +
`X-Timestamp`), so its requests 401. Two things have to change: the *scheme* must
become author-controlled, and *whether/how* a connection signs must become an
**explicit choice**, not an inferred one.

## 2. Two invariants any solution must preserve

Load-bearing in the current code; they constrain the whole design.

1. **The signing secret never enters the runtime sandbox.** The secret is
   encrypted and decrypted *live* in the transport at send. Custom scripts are
   "operator-authored but **untrusted at runtime**." A script that could read the
   secret could leak it into a header, the stored descriptor, or a reflected
   response.
2. **The signature is computed fresh at send, per attempt.** The MAC is recomputed
   over the exact body bytes on every send with a send-time timestamp. This keeps
   the anti-replay timestamp honest on retries and lets a rotated secret apply
   without reprocessing the snapshot.

Anything that bakes a timestamp/signature into the dispatch snapshot breaks (2);
anything that hands the script the secret breaks (1).

## 3. The signing scheme is an explicit choice

`signing` is a tagged union on the connection's transport config (mirroring the
existing `auth` union), so the scheme — and whether to sign at all — is selected
explicitly. There is no implicit "secret present ⇒ on" and no precedence table:
**the variant *is* the answer.**

```
signing  (Ash.Union, tagged :type)   -- on the transport config (HttpConfig)
  none    → {}                                    -- DEFAULT; structurally unsigned
  stripe  → { secret, header_name }               -- native built-in
  custom  → { secret, source, runtime,            -- the Lua signing behaviour (§4)
              algorithm, encoding }               -- allowlisted primitives (§9)
```

- **`none`** is the default and carries no secret field at all, so "secret but no
  scheme" / "scheme but no secret" are *unrepresentable* — the ambiguity in §1
  can't be expressed.
- **`stripe`** and **`custom`** each carry their own `secret` (`ash_cloak`-encrypted,
  required and validated non-blank at save). The standalone top-level
  `signing_secret` attribute goes away; the secret lives in the variant that uses
  it.
- **Built-ins are native Elixir** — efficient, no sandbox. `stripe` is today's
  scheme, with `header_name` defaulting to **`stripe-signature`** (lowercased on
  the wire) and payload `"<unix_seconds>.<body>"` → `t=<ts>,v1=<hex>`.
- **`custom`** is the escape hatch (§4); novel targets (Acumatica) use it until a
  pattern is common enough to graduate to a native built-in. More built-ins
  (GitHub, Shopify, Slack, a generic canonical/HMAC) are **purely additive** later
  — each a new variant.

### 3.1 Subscription override (custom only)

The one thing that legitimately varies per subscription is a **`custom`** scheme's
*canonical string* (Model-2 gateways sign different field sets per operation). So a
subscription carries an optional **whole-source override**: a `signing_source`
string used **only when the connection's scheme is `custom`**, inheriting that
variant's `secret`, `runtime`, and `algorithm`/`encoding`. Inheriting those is
correct because they're *target-uniform* — a gateway's MAC algorithm and output
encoding are fixed by its spec, not varied per operation — so the **only** axis a
subscription legitimately varies is the canonical string, which is exactly what a
source override changes. (A target needing a per-subscription algorithm would be a
reason to revisit; none in scope does.) The effective source is:

```
subscription.signing_source || connection.signing.source     -- custom scheme only
```

An override against a `none`/`stripe` connection is a config error (rejected at
save). **Whole-source**, not per-function merge — per-function merge ("load two
sources, let the second redefine globals") is a luerl-ism that wouldn't port to
other runtimes; whole override keeps "one source = one complete behaviour."

## 4. The `custom` scheme: a staged signing behaviour

`custom.source` implements a small **behaviour** in the runtime — optional
callbacks the library orchestrates at send time, **applying the cryptographic
primitives between the author's pure string-building steps**. The author returns
strings/tables; the library does the hashing and the keyed HMAC. This resolves
three tensions at once:

- **Serialization isn't dictated** — the author builds the exact string to hash.
- **Portability** — callbacks are serializable-data-in / data-out (the same
  boundary `transform` already uses); because crypto runs host-side *between*
  callbacks, the guest needs **no host-imported crypto functions**, so it ports to
  a WASM guest as ordinary exports.
- **Secret isolation** — the secret only ever touches the library's HMAC step.

### 4.1 The callbacks (all optional, with defaults)

| Callback | Returns | Library then does |
|---|---|---|
| `content(ctx)` | the exact string to hash *(default: the encoded wire body)* | computes the digest → exposes `ctx.digest` (hex/base64) |
| `string_to_sign(ctx)` | the string to MAC *(default: `ctx.now.unix_seconds .. "." .. ctx.body`)* | `HMAC(secret, …)`, encodes → `ctx.signature` |
| `headers(ctx)` | a table of headers to merge (weave in `ctx.signature`/`ctx.now`) | merges them in, library-owned precedence |
| `body(ctx)` | a modified body **term** *(Model 2 only)* | encodes it once → wire body |
| `url(ctx)` | a modified URL string *(Model 2 only)* | re-checks egress, sends to it |

Because every callback has a default, a `custom` source that overrides *nothing*
still produces a signature — the default `string_to_sign` (`unix_seconds.body`)
placed in a default `x-signature` header. That degenerate case isn't worth a
`custom` scheme (it's roughly the `stripe` built-in minus the `t=…,v1=…` header
formatting); `custom` earns its keep by overriding the steps a target actually
needs.

### 4.2 The pipeline (what the library does at send, for `custom`)

1. Encode the body to bytes **once** → cache as the wire body.
2. `ctx.digest = hash(content(ctx) or wire body)` under the scheme's `algorithm`.
3. `ctx.signature = encode(HMAC(secret, string_to_sign(ctx)), encoding)` under the
   scheme's `algorithm`/`encoding`.
4. Apply whichever placement callbacks exist: `headers` (merge), `url` (string),
   `body` (term → encode once).
5. Send.

### 4.3 Frozen send-context

The library freezes a single send-context at the **start of each attempt** — `now`,
in several formats — and passes that *same frozen value* to every callback.
Mandatory for correctness: `string_to_sign` may bake the timestamp into
the signed string while `headers` puts the same timestamp in `X-Timestamp`; if the
two reads differed the server would rebuild a different string and reject it. Across
**retries** the context advances (fresh anti-replay each attempt) — within one
attempt it's stable. Callbacks are pure functions of `(ctx, frozen-context)`, which
is also what makes them safe to re-run on retry.

### 4.4 `ctx` (HTTP transport)

Plain serializable data — structured, **read-only**; the author never receives or
edits a byte blob.

| Field | Meaning |
|---|---|
| `ctx.method` | upper-case HTTP method |
| `ctx.url`, `ctx.path`, `ctx.host` | full URL, path **incl. query**, host |
| `ctx.headers` | the resolved headers about to be sent |
| `ctx.body` | the encoded wire body string (what Model 1 hashes by default) |
| `ctx.data` | the structured body (read-only) — for building canonical strings in Model 2 (numbers are luerl floats — format explicitly when signing; see §5) |
| `ctx.now.unix_seconds` / `unix_millis` / `iso8601` / `rfc1123` | frozen send time (ISO-8601 ms-precision `Z`; RFC-1123 HTTP-date) |
| `ctx.digest` / `ctx.digest_base64` | hex / base64 of `content` under the scheme's `algorithm`; available to `string_to_sign` onward |
| `ctx.signature` | available to the placement callbacks |

### 4.5 Failure handling and logging

**Retry.** A send-time `custom` failure — the script raises, hits a resource limit,
or returns a bad shape (a missing or non-string `string_to_sign` result, a
non-table `headers` result, etc.) — is a `:transport` failure and is **retryable**.
(`algorithm`/`encoding` are scheme config validated at save, so they can't fail
here.) Distinguishing an author bug from a transient sandbox kill is unreliable, so
we don't try: the existing two-level
suspension is the backstop, so a deterministically-broken script bumps the failure
counter and auto-suspends rather than looping forever. (Cheap future tightening:
treat a deterministic *bad return shape* as non-retryable so it fails fast and in
isolation — not needed for v1.)

**Logging / redaction.** The **secret** never enters the descriptor or the sandbox
(invariant 1), so custom signing adds no secret-leak surface. The **signature** is
not a credential — it's a per-request MAC, useless without the secret and already
sent in the clear — and for header/url placement it's injected *live* at send and
never snapshotted, so (like today's `x-signature`) it isn't in the persisted
descriptor at all. The only case where a signature reaches a stored payload is a
Model-2 **body** field; being low-sensitivity, we don't guess author-chosen header
names to redact it. If we ever want it scrubbed from logs, redact by **value** (we
generated the exact signature string) — placement- and name-agnostic, far more
robust than name matching.

## 5. The two verification models (and the body-bytes guarantee)

Applies to `custom` (the built-ins are fixed and known-correct). A signature is
verified one of two ways, and embedded signatures force the second:

- **Model 1 — re-hash exact transmitted bytes (detached).** Header/query schemes
  (Stripe, GitHub, Acumatica). The signature sits outside the body; the receiver
  re-hashes the raw body bytes, so **byte fidelity is everything**.
- **Model 2 — re-parse and re-extract fields (embedded).** The signature is a
  field *inside* the body (payment gateways). The receiver parses, removes the
  signature field, rebuilds a canonical string from the remaining **field values**,
  and recomputes. Byte fidelity is irrelevant. (Embedded *must* be Model 2 — you
  can't sign bytes that contain the not-yet-computed signature.)

**The guarantee, by construction.** Round-tripping a structured body through the
sandbox and re-encoding can change bytes even when the author touched nothing
(luerl has only floats: `100`→`100.0`; map key order can shift). We avoid
*detecting* this (a diff can't tell author-edit from luerl-drift). Instead:

- the body is encoded **exactly once**, and
- a placement `body` callback existing is the *only* trigger for re-encoding.

So **no `body` callback ⇒ the cached encoded bytes are sent verbatim** — the same
bytes that were hashed. Model 1 is byte-identical for free, no diffing. A `body`
callback ⇒ the author is in Model 2 (signed a derived canonical string, not the
bytes), so re-encoding is fine — the receiver re-extracts fields.

- **`url`** is a string, so no drift hazard; the only caveat is *logical* ordering
  (don't sign over the URL and then change it, unless the added part is excluded
  from what you signed). Documented, not silent corruption.
- **Incoherent combo, only *partly* catchable:** signing the raw body **and** then
  changing it. The *default*-`content` + `body`-callback case is rejected
  structurally at save (purely from which callbacks exist) — no runtime diff. But
  the variant where the author *overrides* `content` yet still hashes the raw body,
  then also defines `body`, is the same logical error and **cannot** be caught
  structurally (we can't introspect what `content` returns). So "caught
  structurally" covers the default-`content` case only; the override case is a
  documented footgun.
- **luerl number coercion reaches author-built strings, not just the body.** The
  guarantee above is about the *body re-encode* path. A separate, related footgun:
  a Model-2 author builds `string_to_sign` from `ctx.data` **inside luerl**, where
  every number is a float — `100` can stringify as `100.0`, and large integers can
  lose precision. That produces a *valid signature over the wrong string* → a
  silent 401, the exact failure this design fights. The library can't fix it (it's
  the author's string), so it must be **documented loudly**, with guidance to
  format numbers explicitly (`string.format("%d", n)`, or the gateway's required
  precision) rather than relying on `tostring`. Surfaced on `ctx.data` (§4.4).
- **Unsupported sub-case:** embedded *and* the receiver re-hashes the exact
  transmitted bytes. `Jason.encode!` gives no canonical-JSON (JCS) guarantee, so
  those bytes aren't bit-reproducible cross-implementation. Rare/ill-defined;
  documented as unsupported.

## 6. Placement = separate optional callbacks (not a placement DSL)

`headers` / `body` / `url` are **separate optional functions**, each returning its
piece in its natural shape, rather than one `finalize` returning a whole descriptor
or a declarative placement map. Why:

- **The byte guarantee becomes structural** — §5 (absence of `body` = no re-encode).
- **No byte-blobs** — headers return a table, url a string, body a *term*; each
  only invoked when the author opts in.
- **Full code, not templates** — conditionals, merges, computed values.
- **Most signers implement exactly one** (Acumatica → `headers`; gateway → `body`;
  presigned URL → `url`).

Performance: the source is **compiled once** per send into a single sandbox state;
which callbacks are present is detected in that same compile run; then each
*defined* callback is invoked on that already-compiled state — no source re-parse,
and undefined callbacks cost nothing. The whole pipeline runs under **one** Task and
**one** wall-clock budget (not one-per-callback), and the keyed MAC happens in
Elixir between calls, with **results threaded** there (digest → `string_to_sign` →
signature → placement). Callbacks stay pure functions of `ctx`: the compiled state
is reused immutably, so a callback can't leak globals into the next. (`none`/`stripe`
are native and never touch the sandbox at all.)

## 7. Coverage

`custom` model: "guest builds one string → library does one keyed MAC → guest
places it." Native built-ins shipped now: `none`, `stripe`.

| Scheme | How | Notes |
|---|---|---|
| unsigned | `none` | default |
| Stripe (`t=…,v1=…`) | `stripe` built-in | header default `stripe-signature` |
| GitHub / Shopify / Slack | `custom` now → built-in later | single-MAC header schemes |
| Acumatica (canonical request) | `custom` | motivating case; `content`+`string_to_sign`+`headers` |
| Body-embedded gateways | `custom` | Model 2, `body` callback, often per-subscription override |
| Twilio | `custom` ✓ | `algorithm = sha1` + base64; author builds the URL+params string |
| AWS SigV4 | ✗ | **derived signing key** (chained HMACs) — out of scope for one-MAC model |

The remaining boundary is honest: SigV4-style **derived-key** schemes need a separate
mechanism (the guest can't HMAC, the library does exactly one), so they're out of
scope. Worth a README note for the AWS case.

## 8. Wiring (what changes)

1. **Transport config (`HttpConfig`)** — replace the standalone `signing_secret`
   attribute with a `signing` **union** (`none` / `stripe` / `custom`), default
   `none`. Each non-`none` variant is its own embedded resource carrying an
   encrypted `secret` (required, non-blank); `stripe` adds `header_name`
   (default `stripe-signature`, lowercased on the wire in `compute/2`);
   `custom` adds `source` + `runtime` + `algorithm` (`sha256`|`sha1`|`sha512`,
   default `sha256`) + `encoding` (`hex`|`base64`|`base64url`, default `hex`).
   Mirrors the
   `auth` union exactly (incl. `storage: :map_with_tag` and the cloak setup).
2. **Subscription** — add optional `signing_source` (string) override, valid only
   when the connection scheme is `custom` (validated at save); inherits the
   variant's `runtime`.
3. **`Runtime` behaviour / `Runtime.Lua`** — invoke a *set of named callbacks*
   (`content`, `string_to_sign`, `headers`, `body`, `url`) within **one**
   instantiation, threading `ctx` and prior results through globals; the secret is
   never set into the state. A new behaviour callback (e.g. `execute_signing/…`)
   keeps the transport runtime-neutral; the single-`transform` path is unchanged.
4. **`Transport.Signing`** — dispatch on the scheme: `none` → no-op; `stripe` →
   native MAC; `custom` → run the staged pipeline. Freeze the send-context, decrypt
   the secret live, HMAC, apply placements, classify failures.
5. **`Wire.Transports.Http`** — replace the single `signature`/`signature_header`
   step with the scheme dispatch above; for `custom`, encode-once body, run the
   pipeline, apply header/url/body results (re-check egress on a `url` change),
   preserve the encode-once discipline.
6. **`Resolver` / snapshot** — snapshot `signs_at_send?` (scheme is `custom`) so the
   transport only spins the signing sandbox when needed. Ensure the connection's
   `signing` variant and any subscription `signing_source` are in the transport's
   live load.
7. **Validation** — `stripe`/`custom` require a non-blank `secret`; `custom`
   requires a parseable `source`; reject a subscription `signing_source` when the
   connection scheme isn't `custom`; reject the incoherent default-`content` +
   `body` combo.
8. **Docs + tests** — `stripe` parity, Acumatica vector via `custom`, a Model-2
   gateway example, `now`-consistency across callbacks, byte-identity when no
   `body` callback, bad-return classification, sha1/sha512 + base64/base64url
   encoding unit tests, and the `ctx.data` numeric-formatting footgun (§5)
   called out prominently in the authoring guide.

### 8a. Implementation status (this PR)

**Built — the signing engine wired into both transports, with tests:**

- `signing` variant resources (`Signing.None` / `Signing.Stripe` / `Signing.Custom`)
  and the `SigningScheme` union type (cloak-encrypted `secret`; `algorithm`/
  `encoding`/`runtime` as allowlisted enums), on **both** `HttpConfig` and
  `KafkaConfig` (replacing the old `signing_secret` field on each).
- `Runtime.sign_call/4` + the `Runtime.Lua` implementation — invokes a single
  signing callback in the bounded sandbox; the secret is never set into the state.
- `Transport.Signing` — the pure `compute/2` engine (scheme dispatch: `none` /
  native `stripe` / staged `custom`; the digest→HMAC→placement pipeline; the
  algorithm/encoding primitives) plus `run/2` (decrypt the union's secret live,
  then compute, classifying failures) and the frozen `now_context/0`.
- `Wire.Transports.Http` and `Wire.Transports.Kafka` both build the send-time
  `ctx` and apply the result (headers always; body re-encode for a Model-2 `body`
  callback; URL re-pinned through egress for an HTTP `url` callback).
- Save-time `custom` source parse validation (`Validations.SigningSource`).
- Connection form UI: the signing union (scheme select + per-variant fields).
- Tests: `compute/2` unit vectors (`none`, `stripe`, custom defaults, Acumatica
  canonical request, HMAC-SHA1+base64, Model-2 body placement, error paths) in the
  library; the end-to-end connection→transport→header path (real cloak round-trip)
  in the example app's HTTP + Kafka transport suites.

**Follow-up (noted, not in this PR):**

- The per-subscription whole-source override + `signs_at_send?` snapshot (§3.1;
  steps 2, 6) — connection-level signing covers the Model-1 majority today.
- The incoherent default-`content` + `body` save-time rejection (§5).
- Graduating common `custom` recipes (GitHub/Shopify/Slack/canonical) to native
  built-in variants.

## 9. Resolved decisions

1. **Retry** — send-time `custom` signing failures are retryable `:transport`,
   bounded by the two-level suspension backstop (§4.5).
2. **Redaction** — no author-header-name guessing: the secret never reaches logs,
   live signature headers/url aren't persisted, and a Model-2 body signature is a
   low-sensitivity MAC (scrub-by-value if ever needed) (§4.5).
3. **Allowlists** — `algorithm` ∈ `sha256` (default) | `sha1` | `sha512`;
   `encoding` ∈ `hex` (default) | `base64` | `base64url`; per-`custom`-scheme
   config (§3, §8). This also makes Twilio (HMAC-SHA1) expressible.
4. **`ctx.now`** — `unix_seconds`, `unix_millis`, `iso8601` (ms, `Z`), `rfc1123`
   (HTTP-date); frozen per attempt.

**Deferred — `ctx.nonce`.** A nonce only helps schemes that *require* a unique
value in the signature for server-side replay rejection (rare; no in-scope target
needs it). It also interacts awkwardly with at-least-once retries: to keep a retry
from looking like a fresh request (or a replay), a nonce would need to be frozen
**per event**, stable across attempts — not per attempt like `now`. Add it, with
that semantics, only when a target demands it.

(The earlier "no secret / blank secret" ambiguity is resolved by §3: `none` has no
secret; `stripe`/`custom` validate a non-blank one at save.)

## 10. Alternatives considered

- **Implicit on/off** (sign when a secret is present): the original behavior;
  replaced by the explicit `signing` union (§3) to kill the ambiguity.
- **Declarative recipe table** (`template`, `timestamp_format`, …) — too fitted;
  only expresses anticipated schemes.
- **Single `sign` returning `{payload, encoding, headers}` with a `{signature}`
  placeholder** — can't cleanly do body/url placement; would need fragile
  change-detection.
- **Pre-computed body hashes in `ctx`** — forces the library to dictate the body
  serialization before hashing; can't assume it.
- **Host crypto functions in the guest** (`sha256_hex`, HMAC) — secret exposure
  (HMAC) and WASM host-import friction; replaced by "library applies crypto between
  pure callbacks."
- **Per-function override (merge)** — luerl-only merge semantics; portability trap;
  deferred (additive later).
- **Built-in profiles *instead of* custom** — too rigid alone; **adopted as the
  `none`/`stripe`/… variants *alongside* `custom`**, which keeps the common cases
  native/efficient and novel ones unblocked.
- **Let the runtime compute the HMAC** (inject the secret) — breaks invariant 1.
