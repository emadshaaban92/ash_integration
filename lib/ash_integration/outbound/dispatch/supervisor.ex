defmodule AshIntegration.Outbound.Dispatch.Supervisor do
  @moduledoc """
  Root of the **dispatch stage** and the owner of its configuration.

  `AshIntegration.Supervisor` starts this stage supervisor (when the runtime is
  `AshIntegration.enabled?/0`). In its `init/1` it:

    1. reads the host's `:dispatch` config slice,
    2. validates it against `opts_schema/0` (NimbleOptions) — unknown keys and bad
       types fail the boot loudly (fail-fast on config, not lazily at first use),
    3. publishes the value read from *outside* this process tree
       (`:max_dispatch_age_ms`) into `:persistent_term`, and
    4. starts the Broadway relay pipeline.

  ## Config — one nested key, owned by this stage

      config :ash_integration,
        dispatch: [
          concurrency:        System.schedulers_online(),
          max_demand:          2,
          poll_interval_ms:   250,
          batch_size:         100,
          max_dispatch_age_ms: nil
        ]

  Whether this runs at all is the single `AshIntegration.enabled?/0` switch; there
  is no per-stage on/off.

  Every knob names an intent (parallelism, latency, durability policy), not a raw
  pipeline mechanism, so the Broadway implementation behind it can change without
  touching this contract. The one knob that touches Broadway's demand — `max_demand`
  — earns its place by naming a *durability* intent: it caps the standing in-flight
  buffer so a claimed event finishes within its fixed lease (see below), not the
  batcher/partition wiring behind it.

  ## Buffer vs lease

  A claimed event holds its lease (`lease_seconds/0`, a fixed node-liveness constant)
  from claim until its fan-out commits — *including* the time it waits buffered in the
  processor stage behind other events' `project/3` + Lua transforms. That buffer is
  ≈ `max_demand × concurrency` deep. If a healthy node's own still-buffered event
  outlives its lease, another pass/node re-claims it and fans it out again —
  duplicate work absorbed only by the `dispatched_at IS NULL` fence (the `StaleRecord`
  drop in `Changes.DispatchEvent`), the exact path that comment flags as undocumented
  Ash behavior. So the buffer must stay shallow enough to comfortably clear the lease.

  Unlike delivery — whose lease is *derived from* `max_demand` because its per-message
  work is a whole transport round-trip — dispatch keeps the lease a constant and sizes
  the buffer to fit it: `max_demand` defaults to 2 (below Broadway's default of 10),
  so even a slow host `project/3` + heavy transform leaves the buffer comfortably
  inside the 60s lease. Raise it only if you have measured headroom against the lease.

  ## How values reach their readers

  In-tree knobs (`concurrency`, `max_demand`, `poll_interval_ms`, `batch_size`) are
  passed **down** to the relay and producer as start args — nothing reaches back into
  `Application.get_env`. The two values read from *outside* the pipeline tree
  (`Dispatcher.sweep_expired/0`, the dashboard "is this poison?" view) are read via
  `max_dispatch_age_ms/0` and `lease_seconds/0`, backed by `:persistent_term` for
  lock-free O(1) reads, falling back to the schema default when the stage isn't
  running.
  """
  use Supervisor

  alias AshIntegration.Outbound.Dispatch.Relay

  @config_key :dispatch

  # The Broadway batcher fill-timeout: a pure latency-vs-efficiency micro-knob
  # with no host-meaningful intent, so it's an internal constant, not a public
  # knob (exposing it would leak that there's a batcher stage at all).
  @batch_timeout_ms 100

  # Soft-lease window (seconds) before a claimed-but-unfinished Event is reclaimed
  # by another pass/node — a node-liveness backstop, NOT a work timeout: dispatch
  # work (`project/3` + the capped Lua transform + the bulk txn) has no configured
  # timeout to derive a lease from (unlike delivery, whose lease is derived from
  # the transport timeout). Dispatch is idempotent, so a too-short lease only
  # wastes duplicate work, never corrupts — hence an internal constant rather than
  # a host knob. Revisit only if a host's `project/3` can routinely exceed this.
  @lease_seconds 60

  @doc """
  The NimbleOptions schema for the dispatch stage.

  Defined as a function (not a module attribute) so runtime defaults like
  `System.schedulers_online/0` resolve on the *runtime* host, not the build host.
  """
  def opts_schema do
    [
      concurrency: [
        type: :pos_integer,
        default: System.schedulers_online(),
        doc:
          "How many events are fanned out in parallel. Dispatch is DB-bound, so the scheduler count is a sensible default."
      ],
      max_demand: [
        type: :pos_integer,
        # Broadway's own default is 10; this pipeline wants it lower. A claimed event
        # stands leased under the FIXED `@lease_seconds` window while it waits in the
        # processor buffer behind other events' `project/3` + sequential per-subscription
        # Lua transforms. `max_demand × concurrency` is the standing in-flight buffer;
        # keep it shallow so a buffered event comfortably clears the lease and is never
        # re-claimed (duplicate fan-out absorbed only by the `dispatched_at IS NULL`
        # fence). Unlike delivery, dispatch's lease is a constant — the buffer is sized
        # to FIT the lease, not the other way round. 2 is a shallow buffer.
        #
        # SECONDARY EFFECT — this is ALSO the `project/3` batch-size knob. A processor
        # chunk is `≤ max_demand` events, and `prepare_messages` groups that chunk by
        # `{type, version}` and runs `project/3` once per group, so `max_demand` caps
        # how many events a single `project/3` call can amortize over. (The `batch_size`
        # claim is bigger, but it's chopped into `max_demand` chunks before it reaches a
        # processor, so it does NOT grow `project/3` batches — only `max_demand` does.)
        # Since the processors carry no `partition_by` (events spread for concurrency —
        # see `Relay`), raising this is the lever to grow `project/3` batches back. But
        # the LEASE bounds it: a bigger chunk deepens `max_demand × concurrency` and
        # risks a buffered event outliving its lease. So treat batch size as a
        # side-benefit, never a reason to exceed the lease headroom above.
        default: 2,
        doc:
          "Broadway processor `max_demand`: undispatched events each processor prefetches from the producer. Sets the standing in-flight buffer (≈ `max_demand × concurrency`), which must clear the fixed `lease_seconds` window — keep small so a claimed event finishes its fan-out (`project/3` + Lua transform + the batch txn) inside its lease and is never re-claimed."
      ],
      poll_interval_ms: [
        type: :pos_integer,
        default: 250,
        doc:
          "How often the producer re-checks the outbox. Bounds end-to-end idle latency and cross-node discovery cadence; also the correctness backstop."
      ],
      batch_size: [
        type: :pos_integer,
        default: 100,
        doc:
          "Max events claimed from the outbox and fanned out per round. This is ALSO the dispatch transaction size: the relay pins Ash's bulk-update `batch_size` to the batch length so the whole fan-out (stamps + delivery inserts + coalesce UPDATEs) commits atomically, which means one transaction holds locks proportional to batch_size × subscriptions. Keep it modest (hundreds, not tens of thousands) — a very large value trades atomicity for long-held row locks."
      ],
      max_dispatch_age_ms: [
        type: {:or, [:pos_integer, {:in, [nil]}]},
        default: nil,
        doc:
          "Opt-in give-up policy: an undispatched Event older than this (from `created_at`) is taken terminal (`dispatch_terminal_reason: :expired`) by the age sweep, leaving it stuck with its `(connection, event_key)` lane blocked. `nil` (default) = never expire — a dispatch that keeps failing (almost always transient infra) retries forever, one row per lane, so a degraded DB never poisons the backlog. There is deliberately no attempt ceiling: `dispatch_attempts` is an honest counter, not a verdict. See `design/dispatch-terminal-model.md`."
      ]
    ]
  end

  @doc "Validate a `:dispatch` opts keyword against `opts_schema/0`. Raises on unknown keys / bad types."
  def validate!(opts), do: NimbleOptions.validate!(opts, opts_schema())

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = validate!(Application.get_env(:ash_integration, @config_key, []))

    # Publish the cross-tree-read knob for lock-free reads from outside this tree
    # (the age sweep in Dispatcher.sweep_expired, the dashboard poison view).
    put_config(:max_dispatch_age_ms, config[:max_dispatch_age_ms])

    Supervisor.init([{Relay, relay_opts(config)}], strategy: :one_for_one)
  end

  @doc """
  Opt-in max dispatch age (ms) before an undispatched Event is taken terminal
  (`:expired`) by the age sweep; `nil` = never. Cross-tree read; falls back to the
  schema default when the stage supervisor isn't running.
  """
  def max_dispatch_age_ms, do: get_config(:max_dispatch_age_ms)

  @doc """
  Soft-lease window (seconds) a claimed Event is reserved for before reclaim. An
  internal node-liveness backstop, not a host knob — see `@lease_seconds`.
  """
  def lease_seconds, do: @lease_seconds

  @doc """
  Configured `:concurrency` for this stage — the peak number of dispatch Broadway
  batchers each holding a repo connection for the fan-out transaction. Read fresh
  (validated) from config; consumed by the boot-time pool check
  (`AshIntegration.Outbound.PoolCheck`).
  """
  def concurrency do
    Application.get_env(:ash_integration, @config_key, [])
    |> validate!()
    |> Keyword.fetch!(:concurrency)
  end

  @doc false
  def batch_timeout_ms, do: @batch_timeout_ms

  # ── internals ──────────────────────────────────────────────────────────────

  # Only the in-tree knobs are handed to the pipeline; lease/max_dispatch_age_ms are
  # read cross-tree via persistent_term, not threaded through the relay.
  defp relay_opts(config),
    do: Keyword.take(config, [:concurrency, :max_demand, :poll_interval_ms, :batch_size])

  defp get_config(key), do: :persistent_term.get({__MODULE__, key}, default(key))

  defp default(key), do: Keyword.fetch!(defaults(), key)

  defp defaults, do: validate!([])

  # Idempotent on restart: only `put` when the value actually changes, so a
  # stage-supervisor restart with unchanged config does NOT trigger
  # persistent_term's global heap-scan for the replaced term.
  defp put_config(key, value) do
    pt_key = {__MODULE__, key}

    case :persistent_term.get(pt_key, :__unset__) do
      ^value -> :ok
      _ -> :persistent_term.put(pt_key, value)
    end
  end
end
