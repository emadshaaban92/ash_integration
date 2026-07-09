defmodule AshIntegration.Outbound.Delivery.Relay do
  @moduledoc """
  The delivery **relay**: a Broadway pipeline that claims `:scheduled`
  `EventDelivery` rows and executes each one over its transport.

      Producer (claim WHERE state='scheduled', SKIP LOCKED + lease)
        → Processors  (partition_by connection_id)
            handle_message: route to the batcher, keyed by connection
        → Batcher
            handle_batch: per-row decision → `Transport.deliver_batch/2` →
                          `:deliver` / `:record_failure`
        → ack: notify the scheduler so freed lanes promote their next head

  This is the **muscle**; the `EventScheduler` is the **brain**. The scheduler
  promotes `pending`/`:failed → :scheduled` (owning ordering: lane-head selection, the
  high-water gate, suspension, backoff eligibility, terminal gating); this relay only
  *executes* rows already chosen and reports the outcome. The partial unique index
  `(connection_id, event_key) WHERE state IN ('scheduled','failed')` guarantees at
  most one active head per lane, so a claimed batch is a set of DISTINCT-`event_key`
  heads — no intra-batch same-key ordering hazard, and batching (deferred) is
  ordering-safe by construction.

  **Outcomes (per row) — two of them.** A success → `:deliver` (`:delivered`, lane
  freed). Any failure → `:record_failure` (`:scheduled → :failed`, the row keeps its
  lane via the index). `attempts` is never touched here (the claim bumped it). Under
  A1 the relay stamps the timing/verdict it derives from the transport result:

    * non-retryable `:response` (an HTTP 4xx/3xx) → `terminal_reason: :permanent`,
      logged `:permanent`, surfaced loudly — terminal on the first occurrence, even
      while suspended (a deterministic rejection can't recover);
    * retryable on a SUSPENDED entity → no backoff cursor, logged `:probe` — the
      recovery probe (not the row) paces the next try;
    * retryable on a HEALTHY entity → `next_attempt_at` durable backoff (the
      server's clamped `Retry-After` when it sent one, else exponential), logged
      transport/response — the scheduler re-promotes once the backoff elapses.

  There is no attempt ceiling: a retryable failure retries indefinitely (paced by
  backoff and bounded by suspension + the optional age sweep). See
  `design/delivery-retry-model.md`.

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
  alias AshIntegration.Transport.Utils
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
    results = deliver_batch(connection, deliveries)

    Enum.each(messages, fn %Message{data: delivery} ->
      apply_result(delivery, Map.get(results, delivery.id))
    end)
  end

  # `Transport.deliver_batch/2` is contracted to return one `{:ok, _}` / `{:error, _}`
  # per id and NEVER raise — but nothing enforces that. A transport bug that raises
  # would, unguarded, crash the batcher: Broadway fails the whole batch and the
  # acknowledger records NOTHING (no `last_error`, no `next_attempt_at` backoff), so
  # every row stays `:scheduled` and silently retries at the lease cadence forever.
  # Rescue it into a synthetic per-row retryable `:error` (no `retryable`/`failure_class`
  # keys ⇒ retryable, classified `:response`) so each row flows through the SAME
  # `record_failure` path — durable backoff + a visible `last_error` — as a real
  # failure, exactly as a missing per-row result is handled in `apply_result/2`.
  defp deliver_batch(connection, deliveries) do
    Transport.deliver_batch(connection, deliveries)
  rescue
    exception ->
      Logger.error(
        "Outbound delivery: transport raised for connection #{connection.id} — recording " <>
          "#{length(deliveries)} row(s) as a retryable failure:\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      error = {:error, %{error_message: "transport raised: #{Exception.message(exception)}"}}
      Map.new(deliveries, fn delivery -> {delivery.id, error} end)
  end

  # ── Per-row outcome application (with the lease-token fence) ──────────────────

  # A non-deliverable row is a no-op: its state changed between claim and batch
  # (cancelled / already delivered). Suspension is no longer handled here — a
  # suspended row is delivered (the recovery probe) and only diverted on failure.
  defp apply_non_deliver(%Message{data: _delivery}), do: :ok

  defp apply_result(delivery, {:ok, metadata}) do
    metadata = mask_stored_metadata(metadata)

    # Emit `:delivered` only when the fenced `:deliver` actually applied (a stale
    # claimer that lost the lease race wrote nothing).
    case finalize(delivery, :deliver, %{delivery_metadata: metadata}) do
      {:ok, delivered} -> record_delivered(delivery, delivered)
      :error -> :ok
    end
  end

  # Every failure ends the SAME way — `:scheduled → :failed` via `:record_failure`
  # (the relay's only failure outcome) — differing only in the timing/verdict the
  # relay derives (A1) and the class it logs. `attempts` is not touched (the claim
  # bumped it). A `:failed` row keeps its lane via the `{scheduled,failed}` index, so
  # ordering holds and a terminal head blocks its lane.
  defp apply_result(delivery, {:error, metadata}) do
    metadata = mask_stored_metadata(metadata)
    error_message = Map.get(metadata, :error_message, "Unknown error")

    cond do
      permanent_failure?(metadata) ->
        # A non-retryable RESPONSE rejection (an HTTP 4xx/3xx the target refuses
        # regardless of its health). A retry can't fix it, so take it terminal at once:
        # `terminal_reason: :permanent` holds the lane forever (never re-promoted),
        # logged `:permanent` so it stays out of BOTH health windows. Terminal even for
        # a suspended entity — a deterministic rejection can never recover.
        case finalize(delivery, :record_failure, %{
               last_error: error_message,
               delivery_metadata: metadata,
               terminal_reason: :permanent,
               log_failure_class: :permanent
             }) do
          {:ok, _} -> record_terminal(delivery, :permanent, error_message)
          :error -> :ok
        end

      suspended?(delivery) ->
        # A retryable failure for a suspended entity is a recovery-probe attempt, not a
        # row-paced retry: record it `:failed` with NO backoff cursor (`next_attempt_at`
        # stays nil) so the PROBE — not the row's backoff — paces the next try, and log
        # it `:probe` (out of both health windows). On unsuspend the scheduler promotes
        # it immediately.
        finalize(delivery, :record_failure, %{
          last_error: error_message,
          delivery_metadata: metadata,
          log_failure_class: :probe
        })

        :ok

      true ->
        # A retryable failure on a healthy entity: record it `:failed` and stamp the
        # durable `next_attempt_at` backoff — the server's own `Retry-After` pacing
        # when it sent one (clamped by the dispatcher), else exponential — so the
        # scheduler re-promotes it once the backoff elapses (in-order-per-key — the
        # `:failed` head holds the lane). The Log class is classified
        # transport-vs-response from the metadata, scoping the connection/subscription
        # health window.
        finalize(delivery, :record_failure, %{
          last_error: error_message,
          delivery_metadata: metadata,
          next_attempt_at: Dispatcher.backoff_until(delivery.attempts, retry_after_ms(metadata))
        })

        :ok
    end
  end

  # `deliver_batch/2` must return a result for every id; a missing one is a transport
  # contract bug. Treat it as a retryable failure (no `retryable`/`failure_class`
  # keys ⇒ retryable, classified `:response`) so the row is re-tried with backoff
  # rather than silently dropped.
  defp apply_result(delivery, nil) do
    apply_result(delivery, {:error, %{error_message: "transport returned no result"}})
  end

  # A failure is PERMANENT (terminal, no retry) only when it is BOTH non-retryable AND
  # a `:response`-class rejection — a deterministic HTTP 4xx/3xx the target refuses no
  # matter how healthy it is. A non-retryable `:transport` failure (NXDOMAIN, blocked
  # egress, a removed transport, a bad credential) is NOT permanent: it reflects
  # endpoint health, so it keeps feeding the connection window (suspend + probe for
  # recovery) via the ordinary retryable path.
  defp permanent_failure?(metadata) do
    not retryable?(metadata) and response_class?(metadata)
  end

  # A failure is retryable unless it explicitly says otherwise. A missing key ⇒
  # retryable (a transport predating the flag, or the synthesized "no result"
  # contract-bug error, still gets durable backoff). Handles atom (a fresh transport
  # result) and string (a round-tripped map) keys.
  defp retryable?(metadata) do
    case Map.get(metadata, :retryable, Map.get(metadata, "retryable", true)) do
      false -> false
      _ -> true
    end
  end

  defp response_class?(metadata) do
    case Map.get(metadata, :failure_class, Map.get(metadata, "failure_class")) do
      class when class in [:response, "response"] -> true
      _ -> false
    end
  end

  # The server's own pacing for a retryable rejection (`Retry-After`, parsed to ms
  # by the transport), handed to `Dispatcher.backoff_until/2` which clamps it.
  # Missing/invalid ⇒ nil ⇒ ordinary exponential backoff.
  defp retry_after_ms(metadata) do
    case Map.get(metadata, :retry_after_ms, Map.get(metadata, "retry_after_ms")) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> nil
    end
  end

  # Mask any reflected outbound secret (our own `authorization`/`x-signature`/
  # `cookie`/… echoed back by a debug/echo endpoint) in the `response_body` BEFORE
  # it is persisted to `delivery_metadata` and rendered on the dashboard. Done at
  # this single choke point — every transport result flows through here — so any
  # future transport that adds a `response_body` key is covered uniformly. The
  # masked-but-full-size copy stays useful for operators; the 4 KB audit-Log
  # truncation is applied separately when the Log row is written (masking is
  # idempotent, so re-masking there is a no-op). Handles both atom keys (a fresh
  # transport result) and string keys (a round-tripped map).
  defp mask_stored_metadata(%{response_body: body} = metadata),
    do: %{metadata | response_body: Utils.mask_and_cap_response_body(body)}

  defp mask_stored_metadata(%{"response_body" => body} = metadata),
    do: %{metadata | "response_body" => Utils.mask_and_cap_response_body(body)}

  defp mask_stored_metadata(metadata), do: metadata

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

  # Surface a delivery that just went terminal loudly — operator log + `[:ash_integration,
  # :delivery, :terminal]` telemetry, emitted only when the `:failed` write actually
  # applied. The row is left `:failed` (lane blocked) and never auto-resolved.
  defp record_terminal(delivery, reason, error_message) do
    Logger.error(
      "Outbound delivery: #{reason} delivery #{delivery.id} (#{delivery.event_type}, key " <>
        "#{delivery.event_key}) is terminal after #{delivery.attempts} attempt(s) — left " <>
        "`:failed`, lane blocked (no auto-resolve); last error: #{error_message}"
    )

    :telemetry.execute(
      [:ash_integration, :delivery, :terminal],
      %{attempts: delivery.attempts},
      %{
        event_delivery_id: delivery.id,
        event_type: delivery.event_type,
        event_key: delivery.event_key,
        connection_id: delivery.connection_id,
        subscription_id: delivery.subscription_id,
        terminal_reason: reason
      }
    )

    :ok
  end

  # ── Pure decision (unit-testable) ──────────────────────────────────────────────

  @doc """
  Pure decision for a claimed delivery (no I/O), read off the row's state as
  captured in the snapshot loaded just after the claim:

    * `:noop` — no longer `:scheduled`. This only catches a cancel/deliver that
      landed in the narrow claim→snapshot-load window; `state` is a snapshot taken
      microseconds after the claim, so a cancel that arrives AFTER the load is not
      seen here and does NOT stop the send — the transport call still goes out.
      That later race is instead caught at write-back: the fenced `:deliver` in
      `apply_result/2` no-ops against the newer state (the lease-token fence), so a
      late cancel costs no correctness, only the wasted send.
    * `:deliver` — deliver it.

  Suspension is intentionally NOT a gate here. A suspended entity is never given a
  backlog to deliver (the scheduler skips it); the only `:scheduled` row it has is the
  recovery probe's head, promoted by `Health.probe/0`, which MUST hit the transport to
  observe recovery. A suspended delivery's *failure* is what stops it — see
  `apply_result/2`, which records it `:failed` with no backoff (probe-paced) instead
  of a healthy row's durable-backoff retry.
  """
  def decision(%{state: state}) when state != :scheduled, do: :noop
  def decision(_delivery), do: :deliver

  # The claimed row's entity is suspended (as loaded at claim time). On the failure
  # path this records a suspended (probe) delivery `:failed` with no backoff cursor
  # (probe-paced) and logged `:probe`, rather than a healthy row's durable-backoff retry.
  defp suspended?(%{connection: connection, subscription: subscription}) do
    match?(%{suspended: true}, connection) or match?(%{suspended: true}, subscription)
  end

  # Broadway hashes the partition with `rem/2`, so this must be a non-negative
  # integer. Same connection → same processor (so a future batch forms per-connection).
  defp partition_by_connection(%Message{data: %{connection_id: id}}), do: :erlang.phash2(id)
end
