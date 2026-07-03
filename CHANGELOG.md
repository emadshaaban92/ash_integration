# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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

- **A non-retryable response rejection (HTTP 4xx/3xx) is now terminal instead of
  retried forever.** Every transport classifies each failure with a `retryable` flag,
  but the delivery relay ignored it: a deterministic `:response` rejection
  (`retryable: false` — e.g. a 4xx "validation failed") went through the same backoff
  ladder as a transient failure, filled the subscription health window, tripped
  auto-suspension, and then looped on the recovery probe every `probe_interval_ms`
  (~30s) indefinitely — never reaching the backoff cap or the poison ceiling because
  each probe cycle cleared its `attempts`/backoff. The relay now takes a
  **non-retryable `:response` failure** terminal on the FIRST occurrence via a new
  `:record_permanent_failure` outcome (marked terminal with an explicit
  `terminal_reason: :permanent` verdict — never re-claimed, left `:scheduled` so its
  lane stays blocked to preserve per-key order) and surfaces it loudly
  (`[:ash_integration, :delivery, :non_retryable]` telemetry + an operator log). The
  failure is logged as `failure_class: :permanent` — observable but excluded from both
  health windows, so a healthy endpoint returning a 4xx for one bad payload never
  suspends the whole subscription. Non-retryable **`:transport`** failures (NXDOMAIN,
  blocked egress, a removed transport, a bad credential) are deliberately left
  unchanged: they reflect endpoint health, so they keep feeding the connection window
  to drive suspension + recovery probing. A missing `retryable` key still defaults to
  retryable, so third-party transports keep their durable backoff.
- The permanent verdict lives in a new `EventDelivery.terminal_reason` column rather
  than by forcing `attempts` to the poison ceiling, so `attempts` stays a truthful
  count of real delivery attempts. `claim/1`, the recovery-probe picker, and the
  suspend-time park all treat a row as terminal when `attempts >= max_attempts` **or**
  `terminal_reason IS NOT NULL`.
- HTTP `408 Request Timeout` and `429 Too Many Requests` are now classified
  `retryable: true` (transient) instead of being lumped in with deterministic 4xx
  rejections, so the relay backs them off and retries rather than taking them terminal
  on the first hit.

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
