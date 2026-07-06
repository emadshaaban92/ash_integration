# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **TLS certificate verification is now on by default for Kafka and SMTP
  connections.** Previously a Kafka `:tls` / `:sasl_tls` connection sent
  `ssl: true` to kpro, which maps to `verify_none` (no chain or hostname check),
  and the SMTP adapter passed no `tls_options`, so gen_smtp never verified the
  relay's certificate. Both now verify the certificate **chain and hostname**
  (against the OS trust store) by default.
  - **Upgrade behavior — action may be required.** Existing `:tls`, `:sasl_tls`,
    and TLS-using SMTP connections that point at an endpoint with a **self-signed
    or otherwise invalid certificate will start failing to connect** after this
    upgrade, because verification is now enforced. Operators of such internal
    endpoints must set **`verify: :verify_none` on those specific connections**
    (Kafka `security` variant or SMTP `adapter`) to restore the previous
    behavior, or trust the endpoint's private CA via `cacert_pem`. The opt-out is
    per-connection and stored/visible — there is deliberately **no global flag**
    to disable verification everywhere.
  - New per-connection fields: `verify` (`:verify_peer` default | `:verify_none`),
    `cacert_pem`, and `sni` (handshake server-name override) on Kafka
    `:tls`/`:sasl_tls` and SMTP. `cacert_pem` is an **inline
    PEM certificate** stored on the connection record (so a connection is
    self-contained and works across a multi-node cluster with no side-channel
    file); when set it **augments** the OS trust store rather than replacing it.
    An undecodable value is rejected at save time with a field error (and, as a
    delivery-time backstop, classified as a non-retryable transport error).
  - SMTP `tls: :if_available` is unchanged (internal plaintext relays still work),
    but a delivery using it against a non-internal relay now logs a one-time
    warning: STARTTLS can be stripped by an active attacker, so `tls: :always` is
    recommended for internet-facing relays.

- **Hardened the auth/secrets layer.** A pass over the outbound auth, signing, and
  OAuth2 code closed several holes:
  - `req_options` / `oauth2_req_options` can no longer override the transport's
    pinned `redirect: false` / `retry: false`. Both are appended after the pinned
    values and `Req` is last-wins, so `redirect: true` previously re-enabled
    redirect following and let a 3xx bypass the egress IP pin (SSRF) — on both the
    delivery request and the token-endpoint request. Those two keys are now stripped
    from operator `req_options` (with a warning).
  - A secret argument provided as an explicit `nil`, empty string, or whitespace-only
    string is rejected at save time instead of saving a credential with no ciphertext
    (which sent an empty credential, e.g. a bare `"Bearer "`).
  - The api-key and stripe-signing `header_name` are validated at save time and
    rejected if they contain a control character (CR/LF/DEL), matching the guard the
    `custom` signing scheme already applies — a CRLF would split the request and
    crash-loop the delivery outside the failure taxonomy.
  - The OAuth2 token cache no longer lets a timed-out single-flight waiter pick up a
    stale reply on a later fetch, and deregisters the waiter on timeout so the
    leader's late reply doesn't linger as unexpected-message noise.
  - Reserved OAuth2 token-request params (`grant_type`, `scope`, `audience`,
    `client_id`, `client_secret`) smuggled in via `extra_params` are dropped so the
    grant is never sent with duplicate form fields.

### Changed

- **OAuth2 `:basic` token-endpoint auth now form-urlencodes the client id and
  secret** before Base64-encoding them into the `Authorization` header, per RFC 6749
  §2.3.1. **Behavior change:** a `client_id`/`client_secret` containing `:`, `%`, `+`,
  or a space now encodes differently on the wire (correctly). A credential with no
  such characters is unaffected; only a lenient IdP that accepted the previous
  raw-joined form for a special-character secret will see the encoded form instead.


- **BREAKING: reworked the delivery retry / backoff / terminal model** (see
  [`design/delivery-retry-model.md`](design/delivery-retry-model.md)). Timing, attempt
  count, and terminal-ness are now three independent facts, and a new `:failed` state
  holds a lane while a delivery waits or is terminal:
  - `EventDelivery` gains a `:failed` state and a `terminal_reason` column
    (`:permanent` | `:expired`); the lane uniqueness index widens to
    `WHERE state IN ('scheduled','failed')`, so ordering stays a hard DB invariant.
    `:scheduled` now means strictly "in flight now".
  - `attempts` is an honest, **monotonic** count — never forced or reset, and **no
    longer an attempt ceiling**. A retryable failure retries indefinitely, paced by
    `next_attempt_at` backoff and bounded by suspension + the recovery probe. The
    per-row **poison ceiling is removed** (`delivery: [max_attempts: …]` is gone);
    this also eliminates false-poisoning of a slow-but-fine target by lease expiry.
  - The relay is now a dumb executor with two outcomes — deliver, or `:record_failure`
    (`:scheduled → :failed`, stamping `next_attempt_at` **or** `terminal_reason`). All
    retry/terminal/ordering decisions move to the scheduler's promotion.
  - `HTTP 408`/`429` are classified `retryable: true` (transient), so a rate-limit or
    timeout is retried rather than taken terminal. A non-retryable response (a
    deterministic 4xx/3xx) is terminal on the first occurrence (`:permanent`), logged
    with a non-scope `failure_class: :permanent` so one bad payload never suspends a
    healthy subscription.
  - **Config:** `delivery: [max_attempts: …]` is removed; `delivery:
    [max_delivery_age_ms: nil]` is added (opt-in age-based give-up, `nil` = never).
  - **Telemetry:** `[:ash_integration, :delivery, :poison]` is replaced by
    `[:ash_integration, :delivery, :terminal]` (with `terminal_reason`) and
    `[:ash_integration, :delivery, :expired]`.
  - Automatic park-on-suspend is removed: a suspended entity's waiting deliveries
    already sit in `:failed`, and the scheduler simply stops promoting it.
  - A retryable rejection's `Retry-After` header (integer-seconds form) is honored:
    the server's own pacing overrides the exponential backoff, clamped to
    `backoff_max_ms` so a hostile/buggy header can't park a lane indefinitely.
  - **UPGRADE WARNING — pre-existing `:scheduled` rows are NOT migrated.** The old
    claim gated on `attempts < max_attempts` and `next_attempt_at <= now()`; the new
    claim has neither gate (a `:scheduled` row is by construction in flight now —
    but only for rows produced under the new model). On deploy, any **old poisoned
    rows** (left `:scheduled` at/over the removed ceiling) become instantly
    claimable and WILL be retried — a one-time burst against every
    historically-poisoned target (deterministic 4xx go `terminal_reason:
    :permanent` after one attempt; retryable ones re-enter backoff) — and any old
    **in-backoff `:scheduled` rows** get one immediate early attempt before their
    cursor is re-stamped. If that burst is unacceptable (e.g. a large poisoned
    backlog against rate-limited or long-dead targets), triage those rows **before
    deploying**: `cancel` the ones you want skipped, or move them out of
    `:scheduled` yourself — the library deliberately does not guess for you.

- **BREAKING: configurable request signing.** The implicit "secret present ⇒ sign"
  switch and the single hardcoded Stripe-style signer are replaced by an explicit
  `signing` **union** on the transport config (`HttpConfig` and `KafkaConfig`
  alike), mirroring the `auth` union — the variant *is* the choice
  (see `design/configurable-signing.md`):
  - **`none`** (default) — unsigned; carries no secret field, so "a secret with no
    scheme" is unrepresentable.
  - **`stripe`** — the previous scheme as a native built-in (`t=<ts>,v1=<hex>`
    HMAC-SHA256 over `"<unix_seconds>.<body>"`), with a configurable `header_name`
    defaulting to `stripe-signature` (lowercased on the wire).
  - **`custom`** — a staged Lua signing behaviour (`content` / `string_to_sign` /
    `headers` / `body` / `url` callbacks) for novel schemes; the library applies
    the crypto between the pure callbacks, so the secret never enters the sandbox.
    `algorithm` (`sha256`/`sha1`/`sha512`) and `encoding` (`hex`/`base64`/
    `base64url`) are allowlisted config.
  - The old `signing_secret` attribute is **gone** from both transport configs.
    Existing connections load as `signing: none` (i.e. previously-signing
    connections become unsigned) — re-create the scheme as
    `signing: %{type: "stripe", secret: …, header_name: "x-signature"}` (HTTP) or
    `header_name: "signature"` (Kafka) to keep the previous wire contract, or
    accept the new `stripe-signature` default.
  - Script-built signing headers and URLs pass the same trust-boundary guards as
    transform output (string/number/boolean header values only; control characters
    rejected); a `url` placement callback on the Kafka transport is rejected as a
    config error rather than silently ignored.

### Removed

- The `[:ash_integration, :signing, :blank_secret]` telemetry event. A blank
  secret is now rejected at save by the `stripe`/`custom` variants (and `none`
  carries no secret), so the "delivery went out unsigned because the secret was
  blank" condition no longer exists.

### Added

- Telemetry for three outbound state changes that were previously uninstrumented,
  each emitted at the site where the state changes (a reprocess re-park re-emits;
  a cancelled/suppressed delivery never emits `:delivered`):
  - `[:ash_integration, :delivery, :parked]` — a build failure (`failure_kind`
    `:transform`/`:project`), at dispatch and on a reprocess re-park.
  - `[:ash_integration, :connection|:subscription, :suspended]` and the inverse
    `:unsuspended`/`:resumed`.
  - `[:ash_integration, :delivery, :delivered]` — a successful send, with
    `attempts` and source-change → ack `duration_ms`.
- `AshIntegration.Telemetry` (events reference + `events/0`) and an
  [Observability guide](guides/observability.md) enumerating every event.
- **A standing parked-health dimension** so a chronically-parked subscription or
  connection finally surfaces as non-healthy instead of reading green. Park stays a
  recoverable build failure (a broken transform/`project`) — its semantics, and the
  transport/response `consecutive_failures` suspension, are unchanged — but it is no
  longer invisible:
  - New `parked_count` (count of `:parked` deliveries) and `oldest_parked_at` (their
    min `created_at`) aggregates on both the subscription and connection resources,
    filtered to `state == :parked`. Query-time (no migration), added-if-not-exists
    so hosts can override. The connection's span all its subscriptions.
  - A derived health status (`:healthy | :degraded | :parked`) via
    `AshIntegration.Outbound.Delivery.ParkedHealth.status/1`, configurable with
    `parked_health_threshold` (default `10`): zero parked is healthy, a backlog
    below the threshold is degraded, at/above is parked.
  - The dashboard gains a standing **"Parked"** stat (next to "Suppressed (24h)");
    the subscription/connection index + detail pages show the parked count and a
    degraded/parked badge. Load failures surface (they are not swallowed; cf. #14).
    The real-time signal is the `[:ash_integration, :delivery, :parked]` telemetry
    above; these aggregates are the standing/queryable one.
  - **Opt-in parked-suspend (default OFF):** with
    `config :ash_integration, parked_suspension: [enabled?: true, count_threshold: 50]`,
    a subscription whose standing parked backlog crosses the threshold is
    auto-suspended — a *distinct* suspension that is reprocess- + `unsuspend`-
    resumable and **never** bumps `consecutive_failures` (so it is never conflated
    with the failure-counter suspend). Off by default: a parked head already blocks
    only its own lane, so the conservative default is visible/alertable with no
    auto-halt. When it fires it reuses the `[:ash_integration, :subscription,
    :suspended]` event with `failure_class: "parked"` (and `parked_count` in
    measurements), so a suspension monitor catches the opt-in halt.

### Fixed

- **SMTP STARTTLS with `verify: :verify_peer` (the default) no longer fails the
  handshake with `bad_certificate`.** gen_smtp upgrades a plaintext connection by
  calling `ssl:connect/3` on the existing socket without setting
  `server_name_indication`, so verify_peer + the HTTPS hostname match_fun had no
  reference hostname and rejected an otherwise-valid certificate (surfaced as
  `SMTP rejected: :tls_failed`). The SMTP relay host is now passed through as the
  default SNI, so the upgrade verifies. `verify: :verify_none` still bypasses it,
  and an explicit `sni` still wins.

## [0.2.0]

### Changed

- **BREAKING:** The transform is now a **function the source exposes**, not an
  imperative chunk that mutates a global `result`:

      function transform(event, defaults)
        defaults.headers["x-thing"] = event.id
        return defaults              -- return nil to skip
      end

  The runtime calls `transform(event, defaults)` and uses its **return value**.
  This replaces the old "mutate the pre-seeded `result` global" contract — it
  makes `event`/`defaults` explicit parameters, drops the magic global, and maps
  directly onto a WASM guest's exported `transform`, so the runtime seam finally
  fits functional languages, not just Lua's imperative idiom. A source exposing
  no `transform` is a no-op (the pre-seeded `defaults` pass through); returning
  `nil` skips. **Every existing transform must be rewritten** from
  `result.x = …` / `result = nil` to a `transform/2` function that returns the
  descriptor (or `nil`).
- **BREAKING:** Renamed the subscription's `transform_script` attribute to
  `transform_source`. The stored transform is runtime-neutral — Lua source today,
  a WASM guest's module tomorrow — so "script" no longer fits; the name also
  matches the runtime behaviour's `source()` type. Host-app code, forms, or
  queries referencing `transform_script` must switch to `transform_source`. Ships
  a reversible column-rename migration (no data loss).
- Moved the transform-execution modules under a single `Delivery.Transform.*`
  namespace — `Transform.Runtime` (the runtime-neutral behaviour),
  `Transform.Runtime.Lua` (was `LuaSandbox`), `Transform.Limits`, and
  `Transform.Preview` (was `TransformTest`). This frees `Transformer` for its only
  other meaning in this codebase (a `Spark.Dsl.Transformer`). Host apps that
  referenced these modules by name must update the aliases.
- **BREAKING:** Renamed the `:events` relationship to `:deliveries` on both the
  connection and subscription resources. The relationship's destination is the
  `EventDelivery` resource (the per-subscription delivery state machine), not the
  immutable `Event` outbox, so the previous name collided with the genuine
  "Events" concept and the dashboard's "Deliveries" nav. Host apps loading or
  filtering `connection.events` / `subscription.events` must switch to
  `connection.deliveries` / `subscription.deliveries`.

### Added

- Save-time validation of a subscription's `transform_source`, so a broken
  transform is rejected when saved rather than parking every delivery at
  dispatch. Two layers, both only when the source is changing: a static
  parse/size check via the runtime (`Transform.Runtime.validate/2`), then a
  **smoke run** of the script against the producer's `example/1` — exactly as
  dispatch pre-seeds it — that catches the syntactically-valid-but-unrunnable
  class (denied `io`/`os`, `nil`-index, a typo that runs, a non-table result).
  The smoke layer stops before the wire descriptor and the SSRF egress policy
  (dispatch-time concerns) and no-ops when the producer declares no `example/1`.
- A `transform_runtime` attribute on the subscription (atom, default `:lua`),
  selecting the language that interprets `transform_source` per route. Its
  `one_of` constraint is derived from the runtime registry
  (`Transform.Runtime.runtimes/0`), so the persistable set can't drift from the
  dispatchable set. Adding a second runtime is an additive change (a `one_of`
  member + a behaviour impl). Requires a migration (adds a non-null
  `transform_runtime` column defaulting to `"lua"`).
- A `delivered_at` (`:utc_datetime_usec`) attribute on the `EventDelivery`
  resource, stamped once when the `:deliver` action marks a row `:delivered`. It
  records the delivery moment explicitly rather than overloading `updated_at`, so
  "when was this delivered" stays correct even if a delivered row is later
  touched by another update. Requires a migration (adds a nullable column).
- A `last_delivered_at` aggregate on the subscription resource: the `:max` of the
  delivery's `:delivered_at` over `:deliveries` (the timestamp of the
  subscription's most recent successful delivery). Added added-if-not-exists so
  host apps can override it.

### Fixed

- `/integrations/subscriptions` rendered the empty state even when subscriptions
  existed: the index loaded a `last_delivered_at` field that was never defined,
  the read failed, and the error was swallowed into an empty list. The aggregate
  now exists and the load succeeds.
- Outbound LiveViews (subscriptions, connections, deliveries, events, logs) no
  longer swallow load failures into an empty table that looks identical to "no
  results." A genuine load failure (a bug in this library or the host) now
  crashes loudly with a real stacktrace instead of being hidden, while a
  *forbidden* read degrades to the empty state — a host tightening its policies
  hides the list rather than crashing the page.
