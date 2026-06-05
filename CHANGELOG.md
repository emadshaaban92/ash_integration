# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0]

### Changed

- **BREAKING:** Renamed the `:events` relationship to `:deliveries` on both the
  connection and subscription resources. The relationship's destination is the
  `EventDelivery` resource (the per-subscription delivery state machine), not the
  immutable `Event` outbox, so the previous name collided with the genuine
  "Events" concept and the dashboard's "Deliveries" nav. Host apps loading or
  filtering `connection.events` / `subscription.events` must switch to
  `connection.deliveries` / `subscription.deliveries`.

### Added

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
