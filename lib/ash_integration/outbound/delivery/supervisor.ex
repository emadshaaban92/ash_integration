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
          poll_interval_ms: 250,
          batch_size:     100,
          backoff_base_ms:   1_000,
          backoff_max_ms:  300_000,
          max_delivery_age_ms: nil
        ]

  Whether this runs at all is the single `AshIntegration.enabled?/0` switch; there
  is no per-stage on/off.

  ## Lease is derived, not configured

  Unlike dispatch (whose lease is an internal node-liveness constant), the delivery
  lease IS derivable: delivery work has a host-configured, globally-capped timeout
  (`AshIntegration.http_max_timeout_ms/0`; a per-connection `timeout_ms` is validated
  ≤ it). So `lease_seconds/0` is `http_max_timeout_ms + margin`, guaranteeing the
  lease always outlives the slowest attempt — there is deliberately no
  `lease_seconds` knob. A lease sized ≫ the transport timeout bounds both
  duplicate concurrent sends and false poisoning under the soft-lease model.

  ## How values reach their readers

  In-tree knobs (`concurrency`, `poll_interval_ms`, `batch_size`) are passed
  **down** to the relay and producer as start args — nothing reaches back into
  `Application.get_env`. The values read from *outside* the pipeline tree
  (the backoff computation on the failure path, the age-based `:expired` sweep) are
  read via `backoff_base_ms/0` / `backoff_max_ms/0` / `max_delivery_age_ms/0`, backed
  by `:persistent_term` for lock-free O(1) reads, falling back to the schema default
  when the stage isn't running.
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
  def concurrency do
    Application.get_env(:ash_integration, @config_key, [])
    |> validate!()
    |> Keyword.fetch!(:concurrency)
  end

  @doc """
  Soft-lease window (seconds) a claimed delivery is reserved before reclaim.
  DERIVED from the (globally-capped) transport timeout plus a fixed margin — not a
  host knob — so the lease always outlives the slowest attempt.
  """
  def lease_seconds do
    ceil((AshIntegration.http_max_timeout_ms() + @lease_margin_ms) / 1000)
  end

  @doc false
  def batch_timeout_ms, do: @batch_timeout_ms

  @doc false
  def transport_batch_size, do: @transport_batch_size

  # ── internals ──────────────────────────────────────────────────────────────

  # Only the in-tree knobs are handed to the pipeline; max_attempts/backoff/lease are
  # read cross-tree via persistent_term / derivation, not threaded through the relay.
  defp relay_opts(config),
    do: Keyword.take(config, [:concurrency, :poll_interval_ms, :batch_size])

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
