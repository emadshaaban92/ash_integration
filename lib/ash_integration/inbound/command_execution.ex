defmodule AshIntegration.Inbound.CommandExecution do
  @moduledoc """
  Persistence extension for the one host-owned **CommandExecution** resource: one
  row per inbound command, serving as idempotency record, audit trail, and (where
  the transport cannot redeliver) the dead-letter queue. There is no separate DLQ
  table — states are buckets on this row.

  The composite identity `(command_source, command_id)` is the dedup mechanism (a
  unique index); the lease (`claimed_at`), fence (the same `claimed_at` token),
  and durable backoff (`next_attempt_at`) are recovery machinery layered on it —
  the same committed-claim + soft-lease + `claimed_at`-fence triple the outbound
  delivery relay uses.

  > #### Idempotency horizon {: .info}
  >
  > Dedup lasts only as long as the row does. Retention reaps terminal
  > (`:applied`/`:failed`) rows older than `command_days` (default 90), so a
  > redelivery of a command **older than that window** finds no row and
  > re-applies. The reap window *is* the idempotency horizon — size
  > `command_days` above the longest redelivery horizon a transport can present
  > (e.g. raise it before replaying months-old Kafka offsets from zero).

  Host applications attach this extension to their own resource and wire it via
  `config :ash_integration, command_execution_resource: MyApp.Inbound.CommandExecution`.
  The transformer injects schema, actions, identities, and indexes (all
  `if_not_exists`, so hosts can override).
  """

  use Spark.Dsl.Extension,
    transformers: [AshIntegration.Inbound.CommandExecution.Transformer]
end
