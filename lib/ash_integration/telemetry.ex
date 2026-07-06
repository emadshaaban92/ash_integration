defmodule AshIntegration.Telemetry do
  @moduledoc """
  Reference for the `[:ash_integration, …]` `:telemetry` events the outbound
  pipeline emits. See the [Observability guide](observability.html) for each
  event's measurements and metadata.

  Attach to all of them with `events/0`:

      :telemetry.attach_many(
        "my-app-ash-integration",
        AshIntegration.Telemetry.events(),
        &MyApp.Telemetry.handle/4,
        nil
      )

  ## Events

    * `[:ash_integration, :capture, :isolated_failure]` — an isolated `capture`
      raise; the change never reached the outbox.
    * `[:ash_integration, :dispatch, :poison]` — an Event hit the dispatch ceiling.
    * `[:ash_integration, :coalesce, :events_dropped]` — pending deliveries
      collapsed by latest-state coalescing.
    * `[:ash_integration, :delivery, :parked]` — a build failure parked a delivery
      (`failure_kind` `:transform`/`:project`); re-emitted on a reprocess re-park.
    * `[:ash_integration, :delivery, :delivered]` — the target acknowledged a send
      (`duration_ms` is the source-change → ack latency).
    * `[:ash_integration, :delivery, :terminal]` — a delivery went terminal on the
      first occurrence (`terminal_reason: :permanent` — a non-retryable response);
      left `:failed`, lane blocked, never auto-resolved.
    * `[:ash_integration, :delivery, :expired]` — the opt-in age sweep took N
      still-retrying deliveries terminal (`terminal_reason: :expired`).
    * `[:ash_integration, :dedup, :suppressed]` — a delivery suppressed (body unchanged).
    * `[:ash_integration, :connection, :suspended]` /
      `[:ash_integration, :subscription, :suspended]` — derived suspension on a
      recompute transition (no successful outcome in the last `window_attempts`).
    * `[:ash_integration, :connection, :unsuspended]` /
      `[:ash_integration, :subscription, :resumed]` — the inverse `unsuspend` action.
    * `[:ash_integration, :connection, :probe]` /
      `[:ash_integration, :subscription, :probe]` — a bounded recovery probe pass let
      a suspended connection/subscription through (`promoted` metadata says whether a
      head was actually scheduled).
    * `[:ash_integration, :command, :applied]` / `:failed` / `:dead_lettered` /
      `:duplicate` — inbound command-execution outcomes (`:dead_lettered` is the
      loud one — a command stuck at the attempt ceiling with an operator `retry`
      as the recourse).
  """

  @events [
    [:ash_integration, :capture, :isolated_failure],
    [:ash_integration, :dispatch, :poison],
    [:ash_integration, :coalesce, :events_dropped],
    [:ash_integration, :delivery, :parked],
    [:ash_integration, :delivery, :delivered],
    [:ash_integration, :delivery, :terminal],
    [:ash_integration, :delivery, :expired],
    [:ash_integration, :dedup, :suppressed],
    [:ash_integration, :connection, :suspended],
    [:ash_integration, :subscription, :suspended],
    [:ash_integration, :connection, :unsuspended],
    [:ash_integration, :subscription, :resumed],
    [:ash_integration, :connection, :probe],
    [:ash_integration, :subscription, :probe],
    [:ash_integration, :command, :applied],
    [:ash_integration, :command, :failed],
    [:ash_integration, :command, :dead_lettered],
    [:ash_integration, :command, :duplicate]
  ]

  @doc """
  Every `[:ash_integration, …]` event the library emits, for a one-call
  `:telemetry.attach_many/4`.
  """
  def events, do: @events
end
