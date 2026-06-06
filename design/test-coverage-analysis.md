# Test Coverage Analysis & Proposed Improvements

_Analysis date: 2026-06-06_

This document analyzes the current state of automated test coverage across the
`ash_integration` library and its bundled `example/` host app, and proposes a
prioritized set of improvements.

## TL;DR

The hard part — the asynchronous outbound **runtime engine** (scheduler,
dispatch/delivery relays, poison handling, leasing, suspension, transforms,
transports) — is actually tested **well**, but all of that testing lives in the
`example/` app's 170-test integration suite. The problems are structural:

1. **CI never runs the integration suite.** `mix test` in CI only runs the
   library's own thin suite. The 170 tests that exercise the engine are not run
   on any push or PR, so they can rot or break silently.
2. **Library code coverage is effectively unmeasured.** The library's own
   `mix test --cover` reports **7.92%** because its suite never loads the engine.
   The example suite that *does* exercise the engine reports coverage only for
   `Example.*` modules (path-dependency code isn't instrumented), so the
   library's real exercised-coverage number is unknown.
3. **The web / LiveView layer is barely tested** (2 LiveView tests total), and a
   batch of trivially unit-testable pure helpers in the library have no tests.

Fixing #1 and #2 is higher leverage than writing any new test, because they make
the existing 170 tests count and make coverage visible.

## How coverage is structured today

There are two separate suites:

| Suite | Files | LOC | DB? | Style |
|---|---|---|---|---|
| Library (`test/`) | 9 | ~888 | No (`Ash.DataLayer.Simple`) | Pure functions + Spark compile-time DSL checks |
| Example (`example/test/`) | 20 | ~4,410 | Yes (Postgres + `Ecto.Adapters.SQL.Sandbox`) | Full integration against real resources |

The split is deliberate and sound: the library has no Repo of its own, so
DB-backed behavior is exercised through the example host app (`DataCase`,
`ConnCase`, `drain_dispatch!`/`drain_delivery!` helpers, `Req.Test` for HTTP).

### Measured numbers

- `mix test --cover` (library): **7.92% total.** The entire runtime engine
  (`Dispatcher`, `Scheduler`, `Relay`/`RelayProducer` for both dispatch &
  delivery, `Reprocessor`, `Resolver`, `Acknowledger`, every `delivery/changes/*`
  module, `Retention`, `KafkaClientManager`, and the `EventDelivery` /
  `Subscription` / `Log` / `Connection` transformers) does not even appear in the
  report — those modules are never loaded by the library suite.
- `cd example && mix test --cover`: **170 tests, 0 failures, 52.74% total** — but
  every row in that report is an `Example.*`/`ExampleWeb.*` module. The
  `ash_integration` library is a path dependency and is not instrumented, so this
  number does **not** describe library coverage at all.

## What is well covered (via the example suite)

Credit where due — the integration suite is thorough and the test names read like
a spec. Strong coverage exists for:

- **Scheduler** (`event_scheduler_test`, 376 LOC): per-`(connection, event_key)`
  ordering, parallel lanes, parked-lane blocking, high-water gate, livelock
  regression, connection suspend/deactivate, two-level (connection vs.
  subscription) suspension and counter reset.
- **Dispatch** (`event_dispatch_test`, `dispatch_relay_test`): fan-out,
  coalescing, `notify_on_every_change`, transform-park, idempotency, atomic
  materialize+rollback, poison/terminal events, Broadway glue.
- **Delivery relay** (`delivery_relay_test`): claim/lease window, backoff,
  poison ceiling, lease-token fence (stale claimer), suspend-mid-flight,
  end-to-end async pipeline.
- **Resolver / transports** (`delivery_resolver_test`, `transport_http_test`,
  `transport_kafka_test`): transform overrides, header canonicalization,
  control-char rejection, SSRF egress (incl. redirect), live auth/signature
  injection, failure classification (4xx/5xx/connection).
- **Transport utils** (`transport_utils_test`): `build_url`, `load_secret`
  failure path, murmur2 partitioner vs. Kafka, `scrub_reason`, descriptor/response
  redaction.
- **Retention, reprocessor, registry, envelope, producer, transforms,
  subscription validation, secret params** — all have focused tests.

## Gaps & proposed improvements (prioritized)

### P0 — Make the existing tests count (process/infra, not new tests)

1. **Run the example integration suite in CI.** Add a job that runs
   `cd example && mix test` against a Postgres service container. This is the
   single highest-impact change: today the 170 tests that cover the engine never
   run in CI (`ci.yml` runs only root `mix test` plus sobelow on the example
   app). Without this, the real safety net is unenforced.

2. **Measure library coverage and surface it.** Add `excoveralls`, and configure
   the example suite's coverage to instruct cover to include the
   `:ash_integration` application (`test_coverage: [tool: ExCoveralls]` +
   including the dep) so the engine's exercised-coverage is actually reported.
   Then post coverage on PRs. Only after this is the number trustworthy enough to
   set a threshold.

### P1 — Web / LiveView layer (largest genuine gap)

Only `SubscriptionLive.FormComponent` and `SubscriptionLive.Index` have LiveView
tests. Everything else in `lib/ash_integration/web/live/**` has zero coverage,
including handlers that perform **permission checks and state transitions**:

3. **`DeliveryLive.Show` action handlers** — `reprocess`, `reset`, `cancel`. These
   mutate delivery state and gate on `can?/2`; a regression here is a correctness
   *and* authorization risk. Add `Phoenix.LiveViewTest` coverage for each action
   (allowed, forbidden, and load-failure paths).
4. **`ConnectionLive.FormComponent` + `Index` + `Show`** — transport toggle
   (http↔kafka) resetting the route, header/broker row management, blank-secret
   stripping on save, create/edit happy + validation-error paths.
5. **`EventLive.Show` (`mark_dispatched`)** and the index/browser pages
   (`EventLive.All`, `DeliveryLive.All`, `DeliveryLogLive.All`,
   `EventTypeLive.*`, `DashboardLive`) — filter application, pagination, and
   badge rendering.

### P2 — Pure helpers that belong in the (fast, no-DB) library suite

The library suite currently tests only `can?/2` from `Web.Outbound.Helpers`.
Many sibling functions are pure and trivially unit-testable without a DB, yet
have no tests:

6. **`Web.Outbound.Helpers`**: `presence/1`, `page_meta/1`, `empty_page/0`,
   `filtered_path/2`, `humanize/1`, `format_datetime/2`, `parse_int/3`,
   `owner_name/1`, and especially the transport-form plumbing —
   `strip_blank_secrets/1`, `detect_existing_secrets/1`, `inject_headers_map/1`
   (secret handling = correctness/security sensitive).
7. **Badge/predicate helpers**: `DeliveryLive.Helpers.parked?/1` + `state_badge/1`,
   `EventLive.Helpers.stuck?/2`/`dispatched?/1`/`outbox_badge/1`.
8. **`SubscriptionLive.Helpers`**: option builders (`event_type_options/0`,
   `version_options/1`), `sample_event/2`, `transform_preview/4`, route_config
   union dispatch.

These are cheap, fast, and would meaningfully lift the library suite off 7.92%.

### P3 — Targeted engine/security paths worth explicit tests

9. **`require_encrypted_argument` validation** (security-critical: blocks
   persisting unencrypted secrets). Confirm/expand direct coverage of the
   create-vs-update semantics and the AshCloak field-renaming path.
10. **`Signing.signature/2` HMAC + decrypt-failure path.** The library
    `signing_test` covers only the `secret_state/1` classifier; the example HTTP
    test asserts a signature header is present, but the decrypt-failure → classified
    `:transport` error path is not directly asserted.
11. **`KafkaClientManager` GenServer lifecycle** — client start/reuse, idle
    timeout, cleanup. Currently untested (needs brod mocking or a tagged
    integration test).
12. **`Mix.Tasks.AshIntegration.Events`** — 0% coverage; add a smoke test of its
    output.
13. **Real Kafka path**: tests tagged `:kafka_integration` are excluded by
    default. Document how/when they run and consider a CI lane with a Kafka
    service so the brod publish path isn't perpetually unexercised.

## Suggested sequencing

1. P0.1 + P0.2 first — they unlock visibility and enforcement for everything that
   already exists.
2. P2 (pure helpers) next — fast wins that raise the library suite quickly.
3. P1 (LiveView), starting with `DeliveryLive.Show` action/permission handlers.
4. P3 as targeted follow-ups.
