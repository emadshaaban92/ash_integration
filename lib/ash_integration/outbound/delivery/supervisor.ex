defmodule AshIntegration.Outbound.Delivery.Supervisor do
  @moduledoc """
  Root of the **delivery stage** and the owner of its configuration.

  `AshIntegration.Supervisor` starts this stage supervisor (when the runtime is
  `AshIntegration.enabled?/0`). In its `init/1` it:

    1. reads the host's `:delivery` config slice,
    2. validates it against `opts_schema/0` (NimbleOptions) — unknown keys and bad
       types fail the boot loudly (fail-fast on config, not lazily at first use),
    3. publishes the values read from *outside* this process tree (the backoff knobs,
       `:max_delivery_age_ms`) into `:persistent_term`, and
    4. starts the Broadway delivery relay pipeline.

  The delivery relay claims `:scheduled` `EventDelivery` rows directly and executes
  them — the muscle to the `EventScheduler`'s brain (the scheduler still owns
  ordering: lane-head selection, the high-water gate, suspension). This is the
  delivery-side mirror of `AshIntegration.Outbound.Dispatch.Supervisor`.

  ## Config — one nested key, owned by this stage

      config :ash_integration,
        delivery: [
          concurrency:    25,
          max_demand:      4,
          poll_interval_ms: 250,
          batch_size:     100,
          backoff_base_ms:   1_000,
          backoff_max_ms:  300_000,
          max_delivery_age_ms: nil,
          lease_seconds:   nil
        ]

  Whether this runs at all is the single `AshIntegration.enabled?/0` switch; there
  is no per-stage on/off.

  ## Lease: derived-safe by default, overridable

  A claimed delivery holds its lease from claim until its send finishes — *including*
  the time it waits in Broadway's in-flight buffer behind other sends. That buffer is
  ≈ `max_demand × concurrency` deep and drains `concurrency` sends at a time, so the
  worst-case claim→send wait is ≈ `max_demand × http_max_timeout_ms` (the concurrency
  cancels). The lease has to outlive THAT: if a healthy node's own still-buffered row
  outlives its lease, another pass re-claims it — a duplicate send to the customer
  plus an inflated `attempts` (which distorts the backoff exponent).

  So the derived default of `lease_seconds/0` keys off BOTH the (globally-capped)
  transport timeout AND `max_demand`: `max_demand × http_max_timeout_ms + margin`
  (`AshIntegration.http_max_timeout_ms/0`; a per-connection `timeout_ms` is validated
  ≤ it). This is worst-case-safe — it assumes every buffered send ahead burns the
  full timeout — so out of the box a buffered row is never falsely re-claimed. The two
  knobs are a single decision: a deeper buffer (`max_demand`) forces a longer lease,
  which also slows crash recovery (a dead node's in-flight rows wait the lease before
  re-claim) and lengthens the health recompute cadence (`recompute_interval_ms`
  defaults to `lease + 30s`). Keep `max_demand` small — a delivery message is a whole
  transport round-trip, so prefetch buys no batching today (`transport_batch_size` is
  1); raise it only once a batchable transport lands and you want fuller batches.

  Unlike dispatch (whose lease is an internal node-liveness constant), `lease_seconds`
  IS a host knob — but it defaults to `nil`, meaning "use the derived-safe value
  above". An operator who would rather size the lease off *typical* (not worst-case)
  send latency — accepting the consumer-side `event-id` dedup for the rare buffer
  overrun in exchange for faster failover and a tighter health cadence — can set it
  explicitly.

  ## How values reach their readers

  In-tree knobs (`concurrency`, `max_demand`, `poll_interval_ms`, `batch_size`) are
  passed **down** to the relay and producer as start args. The values read from
  *outside* the pipeline tree (the backoff computation on the failure path, the
  age-based `:expired` sweep) are read via `backoff_base_ms/0` / `backoff_max_ms/0` /
  `max_delivery_age_ms/0`, backed by `:persistent_term` for lock-free O(1) reads,
  falling back to the schema default when the stage isn't running. The derived
  `lease_seconds/0` (read by the producer's claim and the health recompute cadence)
  and `concurrency/0` (the boot-time pool check) instead re-read and re-validate the
  config live — both run outside the hot path.
  """
  use Supervisor

  alias AshIntegration.Outbound.Delivery.Relay

  @config_key :delivery

  # The Broadway batcher fill-timeout — a pure latency-vs-efficiency micro-knob with
  # no host-meaningful intent, so it's an internal constant (exposing it would leak
  # that there's a batcher stage at all).
  @batch_timeout_ms 100

  # Per-batch wire grouping. 1 = no real transport batching yet: each `:scheduled`
  # row is delivered on its own `deliver_batch/2` call. Kept an internal constant
  # (not a knob) until a batchable transport lands (CloudEvents batch / a future
  # DB-insert transport), at which point its headline work is the partial-failure
  # demux. The relay already demuxes per row, so growing this is a one-line change.
  @transport_batch_size 1

  # Headroom added to the (globally-capped) transport timeout to derive the soft
  # lease, so the lease always outlives the slowest in-flight attempt.
  @lease_margin_ms 30_000

  # Backoff jitter as a fraction of the computed delay (±), to de-correlate retries
  # across a fleet. An internal constant, not a host knob.
  @backoff_jitter_ratio 0.1

  @doc """
  The NimbleOptions schema for the delivery stage. A function (not a module
  attribute) so any runtime default resolves on the *runtime* host.
  """
  def opts_schema do
    [
      concurrency: [
        type: :pos_integer,
        # Delivery is network-I/O-bound (sends block on the target), so it wants
        # MORE parallelism than the DB-bound dispatch stage (which defaults to the
        # scheduler count). 25 keeps a healthy number of slow sends in flight without
        # exhausting the DB pool on the bookkeeping writes.
        default: 25,
        doc:
          "How many deliveries are sent in parallel. Higher than dispatch — delivery is I/O-bound."
      ],
      max_demand: [
        type: :pos_integer,
        # Broadway's own default is 10; this pipeline wants it lower. `handle_message`
        # is trivial (just routing to the batcher), so each processor forwards its
        # prefetched rows straight through and they stand leased in the batcher queue
        # behind the slow sends. `max_demand × concurrency` is the standing in-flight
        # buffer and thus the driver of the derived lease — keep it small (see the
        # moduledoc). 4 is a modest buffer; there is no send-batching to fill today.
        default: 4,
        doc:
          "Broadway processor `max_demand`: `:scheduled` rows each processor prefetches from the producer. Sets the standing in-flight buffer (≈ `max_demand × concurrency`) and hence the derived `lease_seconds` default. Keep small — a delivery is a whole transport round-trip, so prefetch buys no batching today (`transport_batch_size` is 1)."
      ],
      poll_interval_ms: [
        type: :pos_integer,
        default: 250,
        doc:
          "How often the producer re-checks for due `:scheduled` rows. Bounds idle delivery latency and cross-node discovery cadence; also the correctness backstop."
      ],
      batch_size: [
        type: :pos_integer,
        default: 100,
        doc: "Max `:scheduled` rows claimed per round."
      ],
      backoff_base_ms: [
        type: :pos_integer,
        default: 1_000,
        doc: "Base delay for the durable exponential backoff on a retryable delivery failure."
      ],
      backoff_max_ms: [
        type: :pos_integer,
        default: 300_000,
        doc: "Cap on the exponential backoff delay (5 minutes)."
      ],
      max_delivery_age_ms: [
        type: {:or, [:pos_integer, {:in, [nil]}]},
        default: nil,
        doc:
          "Opt-in give-up policy: a `:failed` delivery still retrying after this age (from `created_at`) is taken terminal (`terminal_reason: :expired`) by the health sweep, blocking its lane like any terminal head. `nil` (default) = never expire — a persistently-failing but retryable delivery retries forever, paced by backoff and bounded operationally by suspension + probe. There is deliberately no attempt ceiling."
      ],
      lease_seconds: [
        type: {:or, [:pos_integer, {:in, [nil]}]},
        default: nil,
        doc:
          "Soft-lease window (seconds) a claimed delivery is reserved before another pass/node may re-claim it. `nil` (default) DERIVES a worst-case-safe value — `max_demand × http_max_timeout_ms + margin` — so the lease outlives the deepest legitimate claim→send wait and a healthy node's buffered row is never falsely re-claimed (no duplicate send). Set an explicit value to override: a shorter lease sized off *typical* send latency trades that safety margin for faster crash recovery and a tighter health cadence, leaning on the consumer-side `event-id` dedup for the rare overrun. The lease also paces `recompute_interval_ms` (defaults to `lease + 30s`)."
      ]
    ]
  end

  @doc "Validate a `:delivery` opts keyword against `opts_schema/0`. Raises on unknown keys / bad types."
  def validate!(opts), do: NimbleOptions.validate!(opts, opts_schema())

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = validate!(Application.get_env(:ash_integration, @config_key, []))

    # Publish the knobs read from OUTSIDE this tree (the backoff computation on the
    # failure path, the age-based `:expired` sweep).
    put_config(:backoff_base_ms, config[:backoff_base_ms])
    put_config(:backoff_max_ms, config[:backoff_max_ms])
    put_config(:max_delivery_age_ms, config[:max_delivery_age_ms])

    Supervisor.init([{Relay, relay_opts(config)}], strategy: :one_for_one)
  end

  @doc """
  Opt-in max delivery age (ms) before a still-retrying `:failed` row is taken
  terminal (`:expired`) by the health sweep; `nil` = never. Cross-tree read; falls
  back to the schema default when the stage supervisor isn't running.
  """
  def max_delivery_age_ms, do: get_config(:max_delivery_age_ms)

  @doc "Base delay (ms) for the retryable-failure exponential backoff."
  def backoff_base_ms, do: get_config(:backoff_base_ms)

  @doc "Cap (ms) on the retryable-failure exponential backoff."
  def backoff_max_ms, do: get_config(:backoff_max_ms)

  @doc "Jitter ratio (±) applied to the computed backoff delay."
  def backoff_jitter_ratio, do: @backoff_jitter_ratio

  @doc """
  Configured `:concurrency` for this stage — the peak number of delivery Broadway
  processors each holding a repo connection for the per-row bookkeeping write
  (`:deliver` / `:record_failure`). Read fresh (validated) from config; consumed by
  the boot-time pool check (`AshIntegration.Outbound.PoolCheck`).
  """
  def concurrency, do: Keyword.fetch!(live_config(), :concurrency)

  @doc """
  Soft-lease window (seconds) a claimed delivery is reserved before reclaim.

  A host knob (`:lease_seconds`) that defaults to `nil`, meaning DERIVE a
  worst-case-safe value from the (globally-capped) transport timeout AND the
  in-flight buffer depth: `max_demand × http_max_timeout_ms + margin`, so the lease
  always outlives the deepest legitimate claim→send wait (see the moduledoc). An
  explicit `:lease_seconds` overrides the derivation.
  """
  def lease_seconds do
    config = live_config()

    case config[:lease_seconds] do
      nil -> derived_lease_seconds(config[:max_demand])
      seconds -> seconds
    end
  end

  defp derived_lease_seconds(max_demand) do
    ceil((max_demand * AshIntegration.http_max_timeout_ms() + @lease_margin_ms) / 1000)
  end

  @doc false
  def batch_timeout_ms, do: @batch_timeout_ms

  @doc false
  def transport_batch_size, do: @transport_batch_size

  # ── internals ──────────────────────────────────────────────────────────────

  # Only the in-tree knobs are handed to the pipeline; backoff/lease are read
  # cross-tree via persistent_term / derivation, not threaded through the relay.
  defp relay_opts(config),
    do: Keyword.take(config, [:concurrency, :max_demand, :poll_interval_ms, :batch_size])

  # Re-read and re-validate the `:delivery` config live (fills defaults). Used by the
  # cross-tree readers that run outside the pipeline tree (`lease_seconds/0`,
  # `concurrency/0`) — not a hot path, so no persistent_term needed.
  defp live_config, do: validate!(Application.get_env(:ash_integration, @config_key, []))

  defp get_config(key), do: :persistent_term.get({__MODULE__, key}, default(key))

  defp default(key), do: Keyword.fetch!(defaults(), key)

  defp defaults, do: validate!([])

  # Idempotent on restart: only `put` when the value actually changes, so a
  # stage-supervisor restart with unchanged config does NOT trigger persistent_term's
  # global heap-scan for the replaced term.
  defp put_config(key, value) do
    pt_key = {__MODULE__, key}

    case :persistent_term.get(pt_key, :__unset__) do
      ^value -> :ok
      _ -> :persistent_term.put(pt_key, value)
    end
  end
end
