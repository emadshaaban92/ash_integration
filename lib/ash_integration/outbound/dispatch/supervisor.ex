defmodule AshIntegration.Outbound.Dispatch.Supervisor do
  @moduledoc """
  Root of the **dispatch stage** and the owner of its configuration.

  `AshIntegration.Supervisor` starts this stage supervisor (when the runtime is
  `AshIntegration.enabled?/0`). In its `init/1` it:

    1. reads the host's `:dispatch` config slice,
    2. validates it against `opts_schema/0` (NimbleOptions) — unknown keys and bad
       types fail the boot loudly (fail-fast on config, not lazily at first use),
    3. publishes the value read from *outside* this process tree (`:max_attempts`)
       into `:persistent_term`, and
    4. starts the Broadway relay pipeline.

  ## Config — one nested key, owned by this stage

      config :ash_integration,
        dispatch: [
          concurrency:      System.schedulers_online(),
          poll_interval_ms: 250,
          batch_size:       100,
          max_attempts:     20
        ]

  Whether this runs at all is the single `AshIntegration.enabled?/0` switch; there
  is no per-stage on/off.

  Every knob names an intent (parallelism, latency, durability policy), never a
  pipeline mechanism (no processor/batcher/demand/partition knobs) — so the
  Broadway implementation behind it can change without touching this contract.

  ## How values reach their readers

  In-tree knobs (`concurrency`, `poll_interval_ms`, `batch_size`) are passed
  **down** to the relay and producer as start args — nothing reaches back into
  `Application.get_env`. The two values read from *outside* the pipeline tree
  (`Dispatcher.claim/1` on the reprocess paths, the dashboard "is this poison?"
  view) are read via `max_attempts/0` and `lease_seconds/0`, backed by
  `:persistent_term` for lock-free O(1) reads, falling back to the schema default
  when the stage isn't running.
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
      max_attempts: [
        type: :pos_integer,
        default: 20,
        doc:
          "Claim attempts before an undispatched Event becomes terminal (poison): left stuck, lane blocked, never auto-resolved."
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
    # (Dispatcher.claim on the reprocess paths, the dashboard poison view).
    put_config(:max_attempts, config[:max_attempts])

    Supervisor.init([{Relay, relay_opts(config)}], strategy: :one_for_one)
  end

  @doc """
  Terminal retry ceiling (poison) for dispatch. Cross-tree read; falls back to the
  schema default when the stage supervisor isn't running.
  """
  def max_attempts, do: get_config(:max_attempts)

  @doc """
  Soft-lease window (seconds) a claimed Event is reserved for before reclaim. An
  internal node-liveness backstop, not a host knob — see `@lease_seconds`.
  """
  def lease_seconds, do: @lease_seconds

  @doc false
  def batch_timeout_ms, do: @batch_timeout_ms

  # ── internals ──────────────────────────────────────────────────────────────

  # Only the in-tree knobs are handed to the pipeline; lease/max_attempts are
  # read cross-tree via persistent_term, not threaded through the relay.
  defp relay_opts(config),
    do: Keyword.take(config, [:concurrency, :poll_interval_ms, :batch_size])

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
