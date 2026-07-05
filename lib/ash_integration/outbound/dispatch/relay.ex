defmodule AshIntegration.Outbound.Dispatch.Relay do
  @moduledoc """
  The outbox **relay**: a Broadway pipeline that claims undispatched `Event`s and
  fans each out into `EventDelivery` rows.

      Producer (claim WHERE dispatched_at IS NULL, SKIP LOCKED + lease)
        → Processors  (partition_by {type, version})
            prepare_messages: load subscriptions + run batched `project/3`  (no txn)
            handle_message:   run the Lua transform → build delivery specs   (no txn)
        → Batcher
            handle_batch:     Ash.bulk_update(:dispatch) — stamp dispatched_at +
                              materialize deliveries + coalesce, ALL in ONE
                              transaction (the change's `after_batch`; `dispatch/2`
                              pins `batch_size` to the batch length so Ash's default
                              100-row chunking can't split it into several txns)
        → ack: notify the scheduler (the stamp already happened in the txn)

  **Prep happens outside the transaction, on purpose.** `project/3` is host code
  (possibly I/O-bound) and the transform is user-authored Lua — both run in the
  processor stage, which holds no DB transaction. A `project`/transform failure is
  turned into a `:parked`/`:cancelled` **spec** (`Dispatch.Specs`), i.e. *data*, so
  it commits as a parked row and can NEVER roll back the batch nor block a sibling
  subscription. Only a genuine DB error inside `handle_batch`'s transaction aborts
  the batch.

  **One bad event can't strand its batchmates.** A batch transaction is
  all-or-nothing; if it fails (infra), we retry each event in its own single-row
  `bulk_update` so a poison row fails alone and the rest still dispatch. Whatever
  still fails is marked `Broadway.Message.failed/2`; the ack records the error and
  leaves it undispatched for the lease to re-emit (the `dispatch_attempts` ceiling
  eventually leaves it stuck — never auto-resolved).

  **Ordering correctness is not this pipeline's job.** The scheduler high-water gate
  owns it, so dispatch may run unordered, parallel, and multi-node. The
  `{type, version}` partition exists so `project/3` runs once per group, not for
  ordering.

  Deployment: one pipeline per node (each claims via `SKIP LOCKED`). The whole
  runtime is gated by the single `AshIntegration.enabled?/0` switch; tests run with
  it off and start their own isolated instance via `start_supervised!/1`.

  Configuration is owned and validated by `AshIntegration.Outbound.Dispatch.Supervisor`,
  which passes the in-tree knobs (`concurrency`, `poll_interval_ms`, `batch_size`)
  down to `start_link/1` — this module never reads `Application.get_env`.
  """
  use Broadway

  alias AshIntegration.Outbound.Delivery.ParkedHealth
  alias AshIntegration.Outbound.Dispatch.RelayProducer
  alias AshIntegration.Outbound.Dispatch.Specs
  alias AshIntegration.Outbound.Dispatch.Dispatcher
  alias AshIntegration.Outbound.Dispatch.Supervisor, as: Stage
  alias AshIntegration.Outbound.Declare.Registry
  alias Broadway.Message

  @doc """
  Start the relay. Accepts `:name` (defaults to `__MODULE__`) plus the dispatch
  tuning knobs; any omitted knob is filled from the stage schema, so tests can run
  isolated instances via `start_supervised!({Relay, name: unique})`.

  `concurrency` drives both the processor and batcher stages — the host tunes one
  parallelism number, not Broadway's two-stage structure.
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
          # Group same-(type, version) onto one processor so `prepare_messages`
          # can run `project/3` once over the group. Not an ordering mechanism —
          # the scheduler gate owns that.
          partition_by: &partition_by_type_version/1
        ]
      ],
      batchers: [
        default: [
          concurrency: config[:concurrency],
          batch_size: config[:batch_size],
          batch_timeout: Stage.batch_timeout_ms()
        ]
      ]
    )
  end

  # ── Processor stage (no transaction) ───────────────────────────────────────

  @impl true
  # Batched prep: per `(type, version)` group, load the candidate subscriptions and
  # run `project/3` once, attaching each event's per-event outcome to its message.
  # Runs in the processor — outside any transaction.
  def prepare_messages(messages, _context) do
    messages
    |> Enum.group_by(fn %Message{data: %{event_type: t, version: v}} -> {t, v} end)
    |> Enum.flat_map(fn {{type, version}, group} -> prepare_group(type, version, group) end)
  end

  defp prepare_group(type, version, messages) do
    events = Enum.map(messages, & &1.data)
    subscriptions = Dispatcher.subscriptions_for(type, version)
    outcome = group_outcome(type, events, subscriptions)

    Enum.map(messages, fn %Message{data: event} = message ->
      %{message | data: %{event: event, subscriptions: subscriptions, outcome: outcome.(event)}}
    end)
  end

  # Returns `fn event -> {:decision, decision} | {:park_all, reason} end`.
  # No subscribers → skip (the event still gets stamped, just no deliveries).
  # No producer (type left the catalog) or `project` raised → park all candidates,
  # fail-closed and recoverable via reprocess.
  defp group_outcome(_type, _events, []),
    do: fn _event -> {:decision, {:skip, "no subscribers"}} end

  defp group_outcome(type, events, subscriptions) do
    case Registry.producer_for(type) do
      nil ->
        reason = "No producer registered for #{type}"
        fn _event -> {:park_all, reason} end

      producer ->
        project_outcome(producer, events, subscriptions)
    end
  end

  defp project_outcome(producer, events, subscriptions) do
    case Specs.project(producer, events, subscriptions) do
      {:ok, decisions} ->
        fn event -> {:decision, Map.get(decisions, event.id, {:skip, "unauthorized"})} end

      {:error, reason} ->
        park = {:park_all, "project error: #{reason}"}
        fn _event -> park end
    end
  end

  @impl true
  # Per-event: run the transform and build this event's delivery specs (outside the
  # transaction), then route to the batcher. The actual writes happen in the batch.
  def handle_message(_processor, %Message{data: %{event: event} = data} = message, _context) do
    specs = Specs.specs_for_event(event, data.subscriptions, data.outcome)

    message
    |> Map.put(:data, %{event: event, specs: specs})
    |> Message.put_batcher(:default)
  end

  # ── Batcher stage (the transaction) ────────────────────────────────────────

  @impl true
  def handle_batch(:default, messages, _batch_info, _context) do
    dispatched =
      case run_dispatch(messages) do
        :ok ->
          messages

        {:error, _reason} ->
          # The whole-batch transaction rolled back (infra). Retry each event in its
          # own single-row transaction so a poison row fails alone and its batchmates
          # still dispatch.
          Enum.map(messages, &retry_one/1)
      end

    # POST-COMMIT: evaluate the opt-in parked-suspend for any subscription that just
    # had deliveries parked (default OFF → no-op). Kept out of the change's
    # `after_batch` so its count/update never runs inside the dispatch transaction —
    # only committed (non-failed) messages are considered.
    evaluate_parked_suspend(dispatched)

    dispatched
  end

  # Subscriptions whose just-committed dispatch produced a `:parked` delivery, read
  # off the specs (their `attrs` carry `state`/`subscription_id`). Failed messages
  # rolled back, so their parked rows don't exist — skip them.
  defp evaluate_parked_suspend(messages) do
    messages
    |> Enum.filter(&match?(%Message{status: :ok}, &1))
    |> Enum.flat_map(fn %Message{data: %{specs: specs}} -> specs end)
    |> Enum.filter(&(&1.attrs.state == :parked))
    |> Enum.map(& &1.attrs.subscription_id)
    |> ParkedHealth.evaluate_parked_suspend()
  end

  # One `bulk_update(:dispatch)` over the batch: stamps `dispatched_at` and
  # materializes every planned delivery (+ coalesce) atomically per batch. The plan
  # rides in via `context`; the change's `after_batch` consumes it inside the txn.
  defp run_dispatch(messages) do
    events = Enum.map(messages, & &1.data.event)
    plan = Map.new(messages, fn %Message{data: %{event: e, specs: s}} -> {e.id, s} end)
    dispatch(events, plan)
  end

  defp retry_one(%Message{data: %{event: event, specs: specs}} = message) do
    case dispatch([event], %{event.id => specs}) do
      :ok -> message
      {:error, reason} -> Message.failed(message, reason)
    end
  end

  defp dispatch([], _plan), do: :ok

  defp dispatch(events, plan) do
    result =
      Ash.bulk_update(events, :dispatch, %{},
        domain: AshIntegration.domain(),
        context: %{dispatch_plan: plan},
        # :stream is the path that runs batch_change + after_batch (our materialize);
        # the default [:atomic_batches, :atomic] would skip them. return_records?
        # so after_batch receives the updated events.
        strategy: :stream,
        # Force the WHOLE Broadway batch into ONE `transaction: :batch` chunk. Ash's
        # bulk_update defaults to `batch_size: 100`, chunking a larger stream into
        # one transaction PER 100 rows — which would (a) break the moduledoc's
        # "all in ONE transaction" atomicity for a host-configured `dispatch:
        # [batch_size: N]` above 100, and (b) turn a `:partial_success` (some chunks
        # committed, some rolled back) into a whole-batch `{:error, _}` that
        # `retry_one` would then re-dispatch over ALREADY-committed events. Pinning
        # `batch_size` to the batch length keeps it a single transaction, so the
        # result is only ever `:success` or `:error` (never `:partial_success`) and
        # a rollback commits nothing for `retry_one` to duplicate.
        batch_size: length(events),
        return_records?: true,
        return_errors?: true,
        stop_on_error?: false,
        # The fan-out creates EventDelivery rows inside after_batch; nothing consumes
        # those as Ash notifications, so don't generate/track them (avoids the
        # "missed notifications" warning on every batch).
        notify?: false,
        authorize?: false
      )

    case result.status do
      :success -> :ok
      _ -> {:error, format_errors(result.errors)}
    end
  end

  defp format_errors([]), do: "dispatch failed"

  defp format_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{__exception__: true} = e -> Exception.message(e)
      other -> inspect(other)
    end)
  end

  # Broadway hashes the partition with `rem/2`, so this must be a non-negative
  # integer. Same `(type, version)` → same processor (so `project` batches).
  defp partition_by_type_version(%Message{data: %{event_type: t, version: v}}),
    do: :erlang.phash2({t, v})
end
