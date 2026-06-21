defmodule AshIntegration.Inbound.Execute.Supervisor do
  @moduledoc """
  Root of the **command-execution stage** and the owner of its configuration.

  `AshIntegration.Supervisor` starts this stage (when `AshIntegration.enabled?/0`).
  In `init/1` it reads the host's `:command` config slice, validates it against
  `opts_schema/0` (NimbleOptions — unknown keys / bad types fail boot loudly),
  publishes the knobs read from *outside* this process tree (`max_attempts`, the
  backoff bounds) into `:persistent_term`, and starts the Broadway relay.

  ## Config — one nested key, owned by this stage

      config :ash_integration,
        command: [
          concurrency:      System.schedulers_online(),  # DB-bound, like dispatch
          poll_interval_ms: 250,                          # relay poll cadence
          batch_size:       100,                          # rows claimed per round
          max_attempts:     10,                           # claims before dead-letter
          backoff_base_ms:   1_000,
          backoff_max_ms:  300_000
        ]

  Whether this runs at all is the single `AshIntegration.enabled?/0` switch; there
  is no per-stage on/off. Every knob names an intent (parallelism, latency,
  durability policy), never a pipeline mechanism.
  """
  use Supervisor

  alias AshIntegration.Inbound.Execute.Relay

  @config_key :command

  @batch_timeout_ms 100

  # Soft-lease window (seconds) before a claimed-but-unfinished command is
  # reclaimed. A node-liveness backstop, NOT a work timeout: command apply is
  # DB-bound with no transport timeout to derive a lease from, and the
  # `claimed_at` fence makes a mis-sized lease cost wasted work, not corruption —
  # hence an internal constant rather than a host knob. Matches dispatch (60s).
  @lease_seconds 60

  @doc """
  The NimbleOptions schema for the command stage. A function (not a module
  attribute) so runtime defaults like `System.schedulers_online/0` resolve on the
  runtime host.
  """
  def opts_schema do
    [
      concurrency: [
        type: :pos_integer,
        default: System.schedulers_online(),
        doc:
          "How many commands are executed in parallel. Command apply is DB-bound, so the scheduler count is a sensible default."
      ],
      poll_interval_ms: [
        type: :pos_integer,
        default: 250,
        doc:
          "How often the relay re-checks for claimable `:pending` rows. Bounds idle response-command latency and cross-node discovery cadence."
      ],
      batch_size: [
        type: :pos_integer,
        default: 100,
        doc: "Max `:pending` rows claimed per round."
      ],
      max_attempts: [
        type: :pos_integer,
        default: 10,
        doc:
          "Claims before a transiently-failing command dead-letters (counts claims, so a crash-bump is included — bounds a crash loop)."
      ],
      backoff_base_ms: [
        type: :pos_integer,
        default: 1_000,
        doc: "Base of the exponential transient-retry backoff."
      ],
      backoff_max_ms: [
        type: :pos_integer,
        default: 300_000,
        doc: "Ceiling of the exponential transient-retry backoff."
      ]
    ]
  end

  @doc "Validate a `:command` opts keyword against `opts_schema/0`. Raises on unknown keys / bad types."
  def validate!(opts), do: NimbleOptions.validate!(opts, opts_schema())

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = validate!(Application.get_env(:ash_integration, @config_key, []))

    # Publish the knobs read from outside this tree (the classifier's dead-letter
    # ceiling and backoff bounds in `Inbound.Execute`).
    put_config(:max_attempts, config[:max_attempts])
    put_config(:backoff_base_ms, config[:backoff_base_ms])
    put_config(:backoff_max_ms, config[:backoff_max_ms])

    Supervisor.init([{Relay, relay_opts(config)}], strategy: :one_for_one)
  end

  @doc "Dead-letter ceiling (claims). Cross-tree read; schema default when the stage isn't running."
  def max_attempts, do: get_config(:max_attempts)

  @doc "Base of the transient-retry backoff (ms). Cross-tree read."
  def backoff_base_ms, do: get_config(:backoff_base_ms)

  @doc "Ceiling of the transient-retry backoff (ms). Cross-tree read."
  def backoff_max_ms, do: get_config(:backoff_max_ms)

  @doc "Soft-lease window (seconds) a claimed command is reserved for. Internal constant."
  def lease_seconds, do: @lease_seconds

  @doc false
  def batch_timeout_ms, do: @batch_timeout_ms

  # ── internals ──────────────────────────────────────────────────────────

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
