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
  high-water gate #57, suspension); this relay only executes rows already chosen as
  lane heads. The partial unique index `(connection_id, event_key) WHERE
  state = 'scheduled'` guarantees at most one in-flight row per lane, so a claimed
  batch is a set of DISTINCT-`event_key` heads — there is no intra-batch same-key
  ordering hazard, and batching (deferred to #36) is ordering-safe by construction.

  **Outcomes (per row).** A success → `:deliver` (slot freed). A retryable failure
  → `:record_attempt_error`: stamp `next_attempt_at` (durable backoff), leave the
  row `:scheduled` so the lane stays blocked while it retries (in-order-per-key).
  At the poison ceiling (`attempts >= max_attempts`, counted on the claim) → leave
  `:scheduled`, surface loudly once (#74), never auto-resolve (#60). Suspension
  mid-flight → `:reset_to_pending` (the scheduler re-promotes once unsuspended).

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
          # batch_size = 1 today (no real transport batching yet, #36). The batch_key
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

  defp apply_non_deliver(%Message{data: delivery}) do
    case decision(delivery) do
      :halt_suspended -> finalize(delivery, :reset_to_pending, %{})
      :noop -> :ok
    end
  end

  defp apply_result(delivery, {:ok, metadata}) do
    finalize(delivery, :deliver, %{delivery_metadata: metadata})
  end

  defp apply_result(delivery, {:error, metadata}) do
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

  # `deliver_batch/2` must return a result for every id; a missing one is a transport
  # contract bug. Treat it as a retryable failure so the lease re-emits the row,
  # rather than silently dropping it.
  defp apply_result(delivery, nil) do
    apply_result(delivery, {:error, %{error_message: "transport returned no result"}})
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
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Outbound delivery: #{action} on #{delivery.id} did not apply " <>
            "(stale claim or transient error): #{inspect(reason)}"
        )

        :ok
    end
  end

  # ── Pure decision (unit-testable) ──────────────────────────────────────────────

  @doc """
  Pure decision for a claimed delivery (no I/O):

    * `:noop` — no longer `:scheduled` (cancelled / already delivered between claim
      and execution).
    * `:halt_suspended` — the connection OR the subscription is suspended;
      in-flight delivery must stop (the row resets to `:pending`).
    * `:deliver` — deliver normally.
  """
  def decision(%{state: state}) when state != :scheduled, do: :noop
  def decision(%{connection: %{suspended: true}}), do: :halt_suspended
  def decision(%{subscription: %{suspended: true}}), do: :halt_suspended
  def decision(_delivery), do: :deliver

  # Broadway hashes the partition with `rem/2`, so this must be a non-negative
  # integer. Same connection → same processor (so a future batch forms per-connection).
  defp partition_by_connection(%Message{data: %{connection_id: id}}), do: :erlang.phash2(id)
end
