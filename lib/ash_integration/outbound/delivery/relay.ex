defmodule AshIntegration.Outbound.Delivery.Relay do
  @moduledoc """
  The delivery **relay**: a Broadway pipeline that claims `:scheduled`
  `EventDelivery` rows and executes each one over its transport.

      Producer (claim WHERE state='scheduled' AND due, SKIP LOCKED + lease)
        → Processors  (partition_by connection_id)
            handle_message: route to the batcher, keyed by connection
        → Batcher
            handle_batch: per-row decision → `Transport.deliver_batch/2` →
                          `:deliver` / `:record_attempt_error` / `:reset_to_pending`
        → ack: notify the scheduler so freed lanes promote their next head

  This is the **muscle**; the `EventScheduler` is the **brain**. The scheduler
  promotes `pending → scheduled` (owning ordering: lane-head selection, the
  high-water gate, suspension); this relay only executes rows already chosen as
  lane heads. The partial unique index `(connection_id, event_key) WHERE
  state = 'scheduled'` guarantees at most one in-flight row per lane, so a claimed
  batch is a set of DISTINCT-`event_key` heads — there is no intra-batch same-key
  ordering hazard, and batching (deferred) is ordering-safe by construction.

  **Outcomes (per row).** A success → `:deliver` (slot freed). A NON-retryable failure
  (the transport flagged `retryable: false` — a deterministic HTTP 4xx, blocked
  egress, undecryptable credential) → `:record_permanent_failure`: terminal on the
  FIRST occurrence (forced to the poison ceiling, never re-claimed, lane left blocked),
  surfaced loudly and logged `failure_class: :permanent` so it stays out of the health
  windows — a retry can't fix it and must not falsely suspend a healthy endpoint. A
  retryable failure on a HEALTHY entity → `:record_attempt_error`: stamp
  `next_attempt_at` (durable backoff), leave the row `:scheduled` so the lane stays
  blocked while it retries (in-order-per-key). At the poison ceiling (`attempts >=
  max_attempts`, counted on the claim) → leave `:scheduled`, surface loudly once,
  never auto-resolve. A retryable failure for a SUSPENDED entity → `:reset_to_pending`
  (one-shot): the recovery probe paces re-tries and the attempt count is cleared, so a
  suspended delivery never poisons; the scheduler re-promotes once unsuspended.

  **The lease-token fence.** Every result-writing action is filtered on
  `claimed_at == <the value the claimer saw>` (plus the baked `state == :scheduled`
  guard), so a stale claimer (its lease expired and another pass re-claimed the row)
  can never resurrect or double-finalize it — its write matches nothing and is a
  clean no-op. At-least-once still holds (consumers dedup by `event-id`); the
  derived lease (≫ the transport timeout) makes this window rare in the first place.

  Deployment: one pipeline per node (each claims via `SKIP LOCKED`). The whole
  runtime is gated by `AshIntegration.enabled?/0`; tests run with it off and start
  isolated instances via `start_supervised!/1`. Configuration is owned and validated
  by `AshIntegration.Outbound.Delivery.Supervisor`, which passes the in-tree knobs
  (`concurrency`, `poll_interval_ms`, `batch_size`) down to `start_link/1` — this
  module never reads `Application.get_env`.
  """
  use Broadway

  require Logger
  import Ash.Expr

  alias AshIntegration.Outbound.Delivery.RelayProducer
  alias AshIntegration.Outbound.Delivery.Dispatcher
  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage
  alias AshIntegration.Outbound.Wire.Transport
  alias Broadway.Message

  @doc """
  Start the relay. Accepts `:name` (defaults to `__MODULE__`) plus the delivery
  tuning knobs; any omitted knob is filled from the stage schema, so tests can run
  isolated instances via `start_supervised!({Relay, name: unique})`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    config = Stage.validate!(opts)

    Broadway.start_link(__MODULE__,
      name: name,
      producer: [
        module:
          {RelayProducer,
           poll_interval_ms: config[:poll_interval_ms], claim_limit: config[:batch_size]},
        concurrency: 1
      ],
      processors: [
        default: [
          concurrency: config[:concurrency],
          # Group a connection's rows onto one processor so a future per-connection
          # transport batch forms there. Not an ordering mechanism — the scheduler
          # owns that; distinct lane heads can run in any order.
          partition_by: &partition_by_connection/1
        ]
      ],
      batchers: [
        default: [
          concurrency: config[:concurrency],
          # batch_size = 1 today (no real transport batching yet). The batch_key
          # keeps any future batch single-connection.
          batch_size: Stage.transport_batch_size(),
          batch_timeout: Stage.batch_timeout_ms()
        ]
      ]
    )
  end

  # ── Processor stage ──────────────────────────────────────────────────────────

  @impl true
  # Route to the batcher, keyed by connection so a batch never mixes connections
  # (the per-connection batch grouping; `deliver_batch/2` is always single-connection).
  def handle_message(_processor, %Message{data: delivery} = message, _context) do
    message
    |> Message.put_batch_key(delivery.connection_id)
    |> Message.put_batcher(:default)
  end

  # ── Batcher stage (the sends + bookkeeping) ────────────────────────────────────

  @impl true
  def handle_batch(:default, messages, _batch_info, _context) do
    {deliverable, non_deliver} = Enum.split_with(messages, &(decision(&1.data) == :deliver))

    # Suspension / no-op rows: apply their non-send outcome, never marked failed.
    Enum.each(non_deliver, &apply_non_deliver/1)
    run_deliveries(deliverable)

    # Broadway's `handle_batch/4` contract requires every received message back, or
    # it logs an error per batch. The relay never uses Broadway message status for
    # retry — retry/backoff/poison are all managed in the DB (`next_attempt_at`,
    # `attempts`-on-claim) and the acknowledger only notifies the scheduler — so each
    # message passes through with its status unchanged; the outcomes above are applied
    # purely for their side effects, and we return the original list.
    messages
  end

  # The deliverable rows share one connection (batch_key), so one `deliver_batch/2`
  # call covers them; results come back keyed by delivery id and are demuxed per row.
  defp run_deliveries([]), do: :ok

  defp run_deliveries(messages) do
    connection = hd(messages).data.connection
    deliveries = Enum.map(messages, & &1.data)
    results = Transport.deliver_batch(connection, deliveries)

    Enum.each(messages, fn %Message{data: delivery} ->
      apply_result(delivery, Map.get(results, delivery.id))
    end)
  end

  # ── Per-row outcome application (with the lease-token fence) ──────────────────

  # A non-deliverable row is a no-op: its state changed between claim and batch
  # (cancelled / already delivered). Suspension is no longer handled here — a
  # suspended row is delivered (the recovery probe) and only diverted on failure.
  defp apply_non_deliver(%Message{data: _delivery}), do: :ok

  defp apply_result(delivery, {:ok, metadata}) do
    # Emit `:delivered` only when the fenced `:deliver` actually applied (a stale
    # claimer that lost the lease race wrote nothing).
    case finalize(delivery, :deliver, %{delivery_metadata: metadata}) do
      {:ok, delivered} -> record_delivered(delivery, delivered)
      :error -> :ok
    end
  end

  defp apply_result(delivery, {:error, metadata}) do
    cond do
      # The transport classified the failure as NON-retryable — a deterministic
      # rejection (HTTP 4xx, blocked egress, undecryptable credential) a retry cannot
      # fix. Take it terminal immediately, regardless of suspension: retrying it only
      # burns attempts and, worse, feeds the health window until a healthy endpoint is
      # falsely suspended and the row loops on the recovery probe forever.
      not retryable?(metadata) ->
        record_permanent_failure(delivery, metadata)

      suspended?(delivery) ->
        # A failure for a suspended entity is not a delivery attempt to retry: send the
        # row back to `:pending` (one-shot) so the recovery probe paces the next try,
        # and never let it march toward the poison ceiling. `:record_suspended_failure`
        # clears the lease/backoff/attempts (like `:reset_to_pending`) AND logs the
        # failure as `failure_class: :probe` — observable, but excluded from the health
        # windows so it never perturbs the suspend/unsuspend math.
        finalize(delivery, :record_suspended_failure, %{
          last_error: Map.get(metadata, :error_message, "Unknown error"),
          delivery_metadata: metadata
        })

        :ok

      true ->
        error_message = Map.get(metadata, :error_message, "Unknown error")
        poison? = Dispatcher.poison?(delivery)

        last_error =
          if poison?,
            do: Dispatcher.poison_message(delivery.attempts, error_message),
            else: error_message

        finalize(delivery, :record_attempt_error, %{
          last_error: last_error,
          delivery_metadata: metadata,
          # Backoff is irrelevant for a terminal row (never re-claimed), but harmless.
          next_attempt_at: Dispatcher.backoff_until(delivery.attempts)
        })

        if poison?, do: Dispatcher.record_poison(delivery, error_message)
        :ok
    end
  end

  # `deliver_batch/2` must return a result for every id; a missing one is a transport
  # contract bug. Treat it as a retryable failure so the lease re-emits the row,
  # rather than silently dropping it. No `retryable` key ⇒ retryable (see `retryable?/1`).
  defp apply_result(delivery, nil) do
    apply_result(delivery, {:error, %{error_message: "transport returned no result"}})
  end

  # A non-retryable failure is terminal on the FIRST occurrence: force the row to the
  # poison ceiling (never re-claimed, lane left blocked to preserve per-key order) and
  # surface it loudly. Logged as `failure_class: :permanent`, so it stays observable
  # without perturbing the connection/subscription health windows.
  defp record_permanent_failure(delivery, metadata) do
    error_message = Map.get(metadata, :error_message, "Unknown error")

    finalize(delivery, :record_permanent_failure, %{
      last_error: Dispatcher.permanent_message(error_message),
      delivery_metadata: metadata
    })

    Dispatcher.record_permanent(delivery, error_message)
    :ok
  end

  # A transport failure is retryable unless it explicitly says otherwise. A missing
  # key ⇒ retryable (safe default: a transport predating the flag, or the synthesized
  # "no result" contract-bug error, still gets the durable backoff). Handles both atom
  # (a fresh transport result) and string (a round-tripped map) keys.
  defp retryable?(metadata) do
    case Map.get(metadata, :retryable, Map.get(metadata, "retryable", true)) do
      false -> false
      _ -> true
    end
  end

  # Apply a state-transition action, fenced on the lease token (`claimed_at` the
  # claimer saw) so a stale claimer never finalizes a re-claimed row. An unmatched
  # filter (stale / lost race) or a transient write error is swallowed — the row
  # stays `:scheduled` for the lease to re-emit (at-least-once), never crashing the
  # batcher (which would tear down the pipeline).
  defp finalize(delivery, action, params) do
    delivery
    |> Ash.Changeset.for_update(action, params, authorize?: false)
    |> Ash.Changeset.filter(expr(claimed_at == ^delivery.claimed_at))
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, reason} ->
        Logger.debug(
          "Outbound delivery: #{action} on #{delivery.id} did not apply " <>
            "(stale claim or transient error): #{inspect(reason)}"
        )

        :error
    end
  end

  # `duration_ms` is the source-change → ack latency: the source Event's
  # `created_at` (stamped in the source transaction) to `delivered_at`.
  defp record_delivered(delivery, delivered) do
    :telemetry.execute(
      [:ash_integration, :delivery, :delivered],
      %{
        count: 1,
        attempts: delivery.attempts,
        duration_ms:
          DateTime.diff(delivered.delivered_at, delivery.event.created_at, :millisecond)
      },
      %{
        event_delivery_id: delivery.id,
        event_type: delivery.event_type,
        event_key: delivery.event_key,
        subscription_id: delivery.subscription_id,
        connection_id: delivery.connection_id,
        transport: delivery.connection.transport_config.type
      }
    )

    :ok
  end

  # ── Pure decision (unit-testable) ──────────────────────────────────────────────

  @doc """
  Pure decision for a claimed delivery (no I/O):

    * `:noop` — no longer `:scheduled` (cancelled / already delivered between claim
      and execution).
    * `:deliver` — deliver it.

  Suspension is intentionally NOT a gate here. A suspended entity is never given a
  backlog to deliver (the scheduler skips it and `ParkOnSuspend` drains its
  `:scheduled` rows to `:pending`); the only `:scheduled` row it has is the recovery
  probe's head, which MUST hit the transport to observe recovery. A suspended
  delivery's *failure* is what stops it — see `apply_result/2`, which one-shots it
  back to `:pending` instead of retrying.
  """
  def decision(%{state: state}) when state != :scheduled, do: :noop
  def decision(_delivery), do: :deliver

  # The claimed row's entity is suspended (as loaded at claim time). On the failure
  # path this diverts a suspended delivery to a one-shot `:reset_to_pending` instead
  # of a poison-accruing retry.
  defp suspended?(%{connection: connection, subscription: subscription}) do
    match?(%{suspended: true}, connection) or match?(%{suspended: true}, subscription)
  end

  # Broadway hashes the partition with `rem/2`, so this must be a non-negative
  # integer. Same connection → same processor (so a future batch forms per-connection).
  defp partition_by_connection(%Message{data: %{connection_id: id}}), do: :erlang.phash2(id)
end
