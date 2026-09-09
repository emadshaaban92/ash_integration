# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Recorded a real difference between the two Lua backends' CPU ceilings.** No
  behaviour changes on the pinned `lua 0.4` backend; this documents (and tests)
  what would change if a host moved to `lua 1.0`. Transform sources are
  operator-authored but untrusted at runtime, so the difference matters:
  - On `lua 0.4` the step budget is enforced by **killing** the process running
    the Lua code. `pcall` cannot catch a process kill, so a runaway script always
    parks the delivery.
  - On `lua 1.0` it is enforced by **raising a catchable Lua error**. Total CPU is
    still bounded (the budget is per top-level evaluation and is never refilled,
    so catching it buys nothing), but a script can burn its whole budget, catch
    the error, and still return a deliverable descriptor.
  - Memory moves from the luerl runner's `spawn_opts` to the transform `Task`'s
    own `:max_heap_size` (already set, so the ceiling holds either way).
    Conversely, because `lua 1.0` evaluates in-process, brutal-killing the `Task`
    actually kills the evaluator — the `0.4` hazard where a **blocking** host
    function leaks one unlinked runner per delivery disappears.
  - **Wall-clock is not part of the difference, and the outer `Task` timeout is
    now honest about that.** `lua 0.4` exposes a `max_time` flag `lua 1.0` has no
    equivalent for, but `luerl_sandbox:do_run/3` only reaches its `max_time`
    receive once the runner has already terminated, whenever `max_reductions` is
    set — and the runtime always sets one. The outer `Task` was consequently
    waiting `timeout_ms + 1_000` for an inner timer that never fires, so a script
    configured with `timeout_ms: 300` was stopped at ~1300ms while `last_error`
    reported "timed out after 300ms". The grace is removed: the `Task` now waits
    exactly `timeout_ms` on both backends.
  - On `lua 1.0` the runtime additionally sets `:max_call_depth` and
    `:max_string_bytes` (from the same `Limits`), ceilings `lua 0.4` cannot
    express, so the newer backend is bounded no less tightly.
  - `test/ash_integration/lua_pcall_budget_test.exs` pins all of this on both
    backends.

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

- **Dependencies refreshed for both the library and the example app.** `ash`
  moves to `3.33.1`, which clears the advisories Hex reported against `3.32.0`
  (`Ash.Type.CiString` / `Ash.Type.Decimal` / `Ash.Type.String` constraint
  handling, `parent(...)` filter scoping, `Ash.Type.Union` tag dumping,
  `Ash.Vector` dimension headers, `Ash.Type.UUIDv7` validation) and against
  `3.32.3` (grapheme-counted string length — see the host-config note below).
  Alongside it `mint 1.10.0` clears two Mint DoS advisories (quadratic
  chunk-size parsing, unbounded status-line/chunk-extension buffering) and
  `igniter 0.8.4` a terminal-escape-injection advisory; `mix deps.audit` and
  `mix hex.audit` are clean on both lockfiles. Also bumped:
  `ash_postgres 2.13.1`, `ash_sql 0.7.3`, `ash_cloak 0.4.0`, `ash_phoenix 2.3.25`,
  `phoenix 1.8.13`, `phoenix_live_view 1.2.11`, `req 0.7.4`, `brod 4.6.3`,
  `swoosh 1.28.0`, `tidewave 0.9.0`, `ex_doc 0.40.4`, `usage_rules 1.2.8`,
  `ranch 2.3.0`, `spitfire 0.4.1`, plus the example's
  `ash_authentication 4.14.2`, `ash_authentication_phoenix 2.17.3`,
  `phoenix_live_dashboard 0.9.1`, `telemetry_metrics 1.2.0` and `mimic 2.4.0`.
  `mix.lock.lua1` was regenerated from `mix.lock` so the two still differ only
  in the Lua backend, and `lua` itself stays pinned per lockfile (`0.4` on the
  default, `1.0` on the variant) — that pin is the point of the dual-backend
  matrix, not staleness. The example keeps `dns_cluster 0.2.0` and
  `lua ~> 0.4`: both newer releases are outside the requirements it declares.

- **Hosts must now set `config :ash, :default_string_length_count`.** This is an
  `ash 3.33` requirement, not one this library adds — an app that does not set it
  fails to compile, with an Ash error naming the two choices. Both this repo's
  suite and the example app set `:codepoints`, Ash's recommendation: it matches
  how SQL data layers count, so validation agrees with the database. The choice
  is visible here because a subscription's `transform_source` is capped at
  `max_length: 10_240`; under the legacy `:mixed` setting that cap counts
  graphemes, and one grapheme can carry an unbounded number of combining marks,
  so it would not bound the size of the stored script. See the README's
  "Ash string-length counting" section.

- **The Lua transform runtime now runs on the stable `Lua` API and works on both
  `lua 0.4` and `lua 1.0`.** It previously called `:luerl_sandbox.run/3` directly
  at three sites and hand-reconstructed `%Lua{}` from a raw luerl state at four
  more. `lua 1.0` replaced luerl with its own Elixir Lua 5.3 VM and dropped luerl
  as a dependency, so every transform and signing run would have parked on a 1.0
  install. Everything now goes through `Lua.new/1`, `Lua.eval!/2` and `Lua.get!/2`,
  with the one genuinely version-specific concern — where the CPU ceiling lives —
  isolated in
  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat`.
  - **`lua 0.4` remains the pinned default.** `mix.exs` now accepts
    `~> 0.4 or ~> 1.0`; `mix.lock` still pins `0.4`, and CI runs the full suite
    against **both** (a second lockfile, `mix.lock.lua1`, selected via
    `MIX_LOCKFILE` — which also redirects `deps`/`_build` to per-lockfile trees).
  - **`:luerl` is now a declared dependency** (`optional: true`). Calling
    `:luerl_sandbox` while declaring only `{:lua, "~> 0.4"}` was an undeclared
    dependency; `lua 1.0` has no luerl dependency at all, so it must be declared
    rather than leaned on transitively. Hosts on `lua 1.0` are not forced to carry
    it.
  - **The `lua_sandbox` CPU-budget option is now `:max_steps`** (the runtime-neutral
    `Limits` vocabulary). `:max_reductions` named luerl's own flag, which the
    `lua 1.0` backend has no equivalent for; it is still honoured as a deprecated
    alias, so a host that set it keeps its configured ceiling.
  - **Transform timeouts are now the configured value.** The transform and
    signing `Task`s waited `timeout_ms + 1_000`; the extra second existed to let
    an inner luerl `max_time` fire first, which it never does (see the Security
    section). A subscription configured with a 300ms transform ceiling was
    stopped at ~1300ms. It is now stopped at ~300ms, as configured — a
    **behaviour change** for any host relying on the undocumented extra second.

- **Dispatch now uses an age-based terminal model, not an attempt ceiling.** An
  undispatched `Event` no longer becomes poison after `max_attempts` claims; instead
  `Event.dispatch_attempts` is an honest, monotonic counter that never gates the
  claim, and terminal-ness lives in a new `dispatch_terminal_reason` field
  (`:expired`), set **only** by an opt-in age sweep. This fixes the failure mode
  where the attempt ceiling counted infra flakiness — with `max_attempts: 20` and a
  60s lease, ~20 minutes of degraded-DB operation could poison the entire outbox
  backlog, each event then needing a manual `:reset_dispatch`. With the new default
  (`max_dispatch_age_ms: nil`, never expire), a transient infra failure can never
  make a row terminal — it is simply re-emitted, one row per lane, until it succeeds.
  See `design/dispatch-terminal-model.md`.
  - **Config:** the `dispatch: [max_attempts: 20]` knob is **removed**, replaced by
    `dispatch: [max_dispatch_age_ms: nil]` (opt-in; mirrors delivery's
    `max_delivery_age_ms`).
  - **Schema:** new nullable `dispatch_terminal_reason` column on the Event resource
    (migration `add_dispatch_terminal_reason`).
  - **Telemetry:** `[:ash_integration, :dispatch, :poison]` is **removed**, replaced
    by `[:ash_integration, :dispatch, :expired]` (`%{count}`), emitted by the sweep.
  - **Behavior:** `:reset_dispatch` now clears `dispatch_terminal_reason` and no
    longer zeroes `dispatch_attempts` (the counter stays honest). New
    `Dispatcher.reset_terminal/0` bulk-clears every stuck event in one call. The
    opt-in age sweep runs on the `Retention` GenServer's periodic tick.

- **The dispatch ack now records `dispatch_error`s in bulk.** On a failed dispatch
  the acknowledger called `record_dispatch_errors/1`, which did a sequential
  `Ash.get` + `Ash.update` per failed event — so a whole-batch infra failure over a
  `batch_size`-of-N batch cost ~2·N queries in the ack path. It now writes the failed
  events with `Ash.bulk_update` grouped by the resolved reason, so a batch that fails
  with a shared reason collapses to a single `UPDATE`. The failed path is now
  visibility-only (it records the raw `dispatch_error` and nothing else — no terminal
  verdict, since dispatch has no attempt ceiling); `dispatched_at` is still never
  stamped, and the `mark_dispatched` host seam is still the write path.

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

- **Human-readable `connection_name` / `subscription_name` in the outbound health
  telemetry.** Every event that identified a route only by UUID now also carries
  the readable name, so a backend that cannot join back to Postgres — Loki
  structured metadata, a Grafana panel, Sentry tags — can label the route without
  a lookup. This matters most where the ids are unstable: a reseeded environment
  mints fresh UUIDs, so a static id→name map goes stale while the name does not.
  Affected events: `[:ash_integration, :delivery, :parked]` (both emitters),
  `[:ash_integration, :delivery, :delivered]`,
  `[:ash_integration, :delivery, :terminal]`,
  `[:ash_integration, :connection, :suspended]`, and
  `[:ash_integration, :subscription, :suspended]` (both the derived-health
  transition and the opt-in parked-suspend).

  No event costs a query for its name. Each emit site reads a record the pipeline
  already holds — the delivery relay's claim-time `[:connection, :subscription]`
  load, the loaded subscription the dispatch specs were built from, the record a
  suspension's own filtered update returned — and the dispatch park carries the
  names on the spec precisely because the rows that come back out of the bulk
  insert have no associations loaded. The one place a name is deliberately absent
  is `connection_name` on `[:ash_integration, :subscription, :suspended]`: that
  path holds the subscription only, and loading its connection to label the event
  would be exactly the extra query this avoids.

  `connection_name` is always populated (the `AshIntegration.Connection` extension
  adds `name` `allow_nil?: false`). **`subscription_name` is `nil` unless your
  Subscription resource declares its own `name` attribute** —
  `AshIntegration.Outbound.Delivery.Subscription` adds no `name` of its own (a
  subscription is labelled by its connection plus event type), and the extension
  leaves a `name` you declare yourself intact.

- **Host APIs in the Lua sandbox**, with a built-in `datetime`. A transform (and a
  custom signing script) can now render a timestamp in any timezone, so *which*
  zone to use stays the per-subscription decision it is — the previous workaround
  was baking a pre-converted string into the canonical event data at the producer,
  which took that choice from every other consumer of the same event.

  ```lua
  datetime.to_zone(iso8601, tz)       -- ISO-8601 re-rendered with that zone's offset
  datetime.format(iso8601, tz, fmt)   -- Calendar.strftime-style formatting, in that zone
  ```

  Zones resolve through the **host app's** configured
  `Calendar.TimeZoneDatabase` (`config :elixir, :time_zone_database, …`) — the
  library adds no `tz`/`tzdata` dependency, so that choice stays with the host. No
  configured database, an unknown zone, an unparseable timestamp (including one
  with no UTC offset), or a bad format directive **raises**, parking the delivery
  with the reason rather than putting a silently-wrong timestamp on a wire. The
  API is not a clock: it converts a timestamp the script already holds, so
  transforms stay deterministic across `reprocess`.

  A host app can register its own API modules (anything that does `use Lua.API`):

  ```elixir
  config :ash_integration,
    lua_sandbox: [apis: [MyApp.Integration.LuaAPI]]
  ```

  Registered APIs must be **pure computation** — no I/O, no network, no
  filesystem. A CPU-bound host call runs inside the script's existing
  reduction/heap budgets; a **blocking** one escapes both (luerl's reduction
  watchdog polls a counter a descheduled process never advances, so neither the
  reduction budget nor the wall-clock limit fires) and outlives the outer `Task`
  kill, leaking a runner process per delivery — which is what the purity rule
  protects. Each execution builds a fresh sandbox state, so a script that shadows
  an API global affects only its own run. An `:apis` entry that isn't a `Lua.API`
  module is warned about at boot and then parks **every** transform and signing
  run on the node — APIs load into the state before the author's script does, so
  a script that touches none of them fails too. Built-ins load first and a scope
  collision **replaces the earlier module entirely** (`Lua.load_api/2` resets the
  scope table rather than merging) — both when a host scope claims a built-in's
  and when two host entries claim each other's, in which case `:apis` order
  decides and the last one wins. The same boot check flags both, naming the
  functions that disappear. A host API that raises surfaces its **message** in
  `last_error` (in transforms and signing callbacks alike), whatever exception
  type it raises — not an `inspect`ed exception struct.
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

- **The default sort on every injected browse action is no longer silently
  dropped.** The `:index`, `:for_subscription`, and `:parked` read actions
  injected by the Connection / Event / EventDelivery / Log / Subscription
  transformers declared `sort: [id: :desc]` (`[id: :asc]` for `:parked`) as a
  *flat* keyword list on `Ash.Resource.Preparation.Build`. That builtin reads
  `opts[:options]`, so the sort was discarded with no error and no warning, and
  every one of those actions returned rows in arbitrary order. Because `:index`
  and `:for_subscription` are keyset/offset paginated, this was more than a
  display bug: paging an unordered query can repeat or skip rows, so the
  delivery / log / event browsers could lose rows between pages, and a
  subscription's "Recent deliveries" pane could omit the newest delivery
  entirely. All eight sites now build the preparation with
  `Ash.Resource.Preparation.Builtins.build/1`, which nests the options
  correctly. `:parked` remains ascending (oldest-first replay) by design.

- **The subscription list on a connection is ordered.** Subscription's injected
  `:for_connection` read declared no sort at all, so the subscriptions pane on
  `/integrations/connections/:id` rendered them in whatever order Postgres
  returned. It now sorts `id: :desc` like the other injected browse actions.

- **SMTP STARTTLS with `verify: :verify_peer` (the default) no longer fails the
  handshake with `bad_certificate`.** gen_smtp upgrades a plaintext connection by
  calling `ssl:connect/3` on the existing socket without setting
  `server_name_indication`, so verify_peer + the HTTPS hostname match_fun had no
  reference hostname and rejected an otherwise-valid certificate (surfaced as
  `SMTP rejected: :tls_failed`). The SMTP relay host is now passed through as the
  default SNI, so the upgrade verifies. `verify: :verify_none` still bypasses it,
  and an explicit `sni` still wins.

- **Dispatch/capture correctness fixes.**
  - Dispatch now fans a whole claimed batch out in a **single transaction**
    regardless of `dispatch: [batch_size: N]` (previously Ash's default 100-row
    chunking split a larger batch across transactions, and a partial commit could
    re-dispatch already-committed events). The `batch_size` knob is therefore also
    the dispatch transaction size — see its docs.
  - The `:dispatch` update carries a `dispatched_at IS NULL` fence, so a lease-expiry
    re-claim can't double-dispatch an event (no duplicate deliveries, no misleading
    `dispatch_error`).
  - `EventDelivery`'s `:reprocess` is now guarded to `state in [:pending, :parked,
    :failed]`, so reprocessing an in-flight `:scheduled` row (duplicate delivery) or a
    settled `:delivered`/`:suppressed`/`:cancelled` row (resurrecting final/superseded
    state) is a no-op.
  - `capture_isolation? true` now isolates a producer `throw`/`exit`, not just a
    raise, so those failure modes no longer roll back the host's business action.
  - A non-map `project/3` return now fails closed (parks all candidates) instead of
    crashing the dispatch processor.

- **Upgrade note — host-overridden Event/EventDelivery code interfaces.** The
  injected code-interface set is now applied **per name**: a host that defines one
  interface entry (e.g. `define :create`) keeps it and still receives the *rest* of
  the library's interfaces. Previously any host-defined `:create` interface suppressed
  the **entire** injected set. A host that relied on that as an opt-out (e.g. to keep
  `destroy`/`cancel` off its public interface) will see those functions reappear after
  this upgrade, with no compile error — remove them explicitly if that is not wanted.
  The same applies to the injected `defaults` (`:read`/`:destroy`), which are now
  skipped per action name so a host's explicit `read :read`/`destroy :destroy` no
  longer collides.

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
