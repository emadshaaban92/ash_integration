# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0]

### Changed

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
