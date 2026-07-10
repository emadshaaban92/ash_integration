defmodule AshIntegration do
  @moduledoc """
  Configuration entry point for the event-first outbound pipeline.

  Host apps wire their own resources (carrying the `AshIntegration.Outbound.*`
  extensions) and shared infrastructure by config:

      config :ash_integration,
        otp_app: :my_app,
        connection_resource: MyApp.Outbound.Connection,
        subscription_resource: MyApp.Outbound.Subscription,
        event_resource: MyApp.Outbound.Event,
        event_delivery_resource: MyApp.Outbound.EventDelivery,
        delivery_log_resource: MyApp.Outbound.Log,
        source_domains: [MyApp.Catalog],
        domain: MyApp.Integration,
        repo: MyApp.Repo,
        actor_resource: MyApp.Accounts.User,
        vault: MyApp.Vault

  Per-stage tuning lives under a nested key owned by that stage (each stage
  validates its own slice at boot via NimbleOptions). For example the dispatch
  stage (`AshIntegration.Outbound.Dispatch.Supervisor`):

      config :ash_integration,
        dispatch: [
          concurrency:         System.schedulers_online(),
          poll_interval_ms:    250,
          batch_size:          100,
          max_dispatch_age_ms: nil   # opt-in age give-up; nil = never (no attempt ceiling)
        ],
        delivery: [
          concurrency:         25,
          poll_interval_ms:    250,
          batch_size:          100,
          max_delivery_age_ms: nil,  # opt-in age give-up; nil = never (no attempt ceiling)
          backoff_base_ms:     1_000,
          backoff_max_ms:      300_000
        ],
        retention: [
          interval_ms:   :timer.minutes(1),
          delete_limit:  500,
          delivery_days: 90,
          event_days:    365
        ],
        health: [
          window_attempts:       5,
          # recompute_interval_ms defaults to the soft lease + 30s (so it scales with
          # http_max_timeout); override only to tune recovery latency.
          probe_interval_ms:     30_000,
          probe_batch:           3
        ]

  """

  def config, do: Application.get_all_env(:ash_integration)

  def otp_app do
    Keyword.fetch!(config(), :otp_app)
  end

  def domain do
    Keyword.fetch!(config(), :domain)
  end

  def repo do
    Keyword.fetch!(config(), :repo)
  end

  def actor_resource do
    Keyword.fetch!(config(), :actor_resource)
  end

  def vault do
    Keyword.fetch!(config(), :vault)
  end

  @doc """
  Whether `AshIntegration.Supervisor` runs the library's background pipeline
  (dispatch relay, retention sweeper, delivery scheduler/guardian, Kafka client
  manager, boot checks). Defaults to `true`; set `false` to keep the whole runtime
  out of the supervised tree.

  This is the single on/off for the runtime — there are no per-stage toggles. Tests
  set `enabled?: false` and start exactly the pieces they exercise. A host that
  needs heterogeneous placement (e.g. the relay on one node pool, retention on
  another) composes the individual stage modules (`Outbound.Dispatch.Supervisor`,
  `Outbound.Retention`, …) into their own tree directly instead of using this
  umbrella supervisor.
  """
  def enabled? do
    Keyword.get(config(), :enabled?, true)
  end

  # The runtime pipeline now started by `AshIntegration.Supervisor`: the dispatch
  # relay, the delivery scheduler, the delivery relay, the retention sweeper, the
  # Kafka client manager, and the boot checks. (The per-delivery Oban worker and the
  # DeliveryGuardian were removed — the delivery relay claims `:scheduled` rows
  # directly and a soft lease replaces orphan reconciliation.)

  # ── Event-first persistence resources (Outbound.* extensions) ─────────────
  # Host-owned resources carrying the `AshIntegration.Outbound.*` extensions.

  def connection_resource do
    Keyword.fetch!(config(), :connection_resource)
  end

  def subscription_resource do
    Keyword.fetch!(config(), :subscription_resource)
  end

  @doc "The immutable `Event` (the fact) — captured once in the source txn."
  def event_resource do
    Keyword.fetch!(config(), :event_resource)
  end

  @doc "The per-subscription `EventDelivery` (the delivery state machine)."
  def event_delivery_resource do
    Keyword.fetch!(config(), :event_delivery_resource)
  end

  def delivery_log_resource do
    Keyword.fetch!(config(), :delivery_log_resource)
  end

  @doc """
  Domains scanned to build the event-first source registry
  (`AshIntegration.Outbound.Declare.Registry`). Each domain's resources are filtered to
  those carrying the `AshIntegration.Outbound.Declare.Source` extension.
  """
  def source_domains do
    Keyword.get(config(), :source_domains, [])
  end

  @doc """
  Parked-backlog count at/above which a connection/subscription's derived health
  reads `:parked` (chronically parked — UNHEALTHY) rather than `:degraded` (some
  parking — investigate). Below it, any parked delivery reads `:degraded`; zero
  parked reads `:healthy`. See `AshIntegration.Outbound.Delivery.ParkedHealth`.

  This is a **display/alerting** dimension only — it never halts delivery and is
  independent of the derived transport/response suspension
  (`AshIntegration.Outbound.Delivery.Health`). Park stays a recoverable build
  failure cleared by `reprocess`. Defaults to `10`.
  """
  def parked_health_threshold do
    Keyword.get(config(), :parked_health_threshold, 10)
  end

  # ── Opt-in parked-suspend (default OFF) ───────────────────────────────────
  # A chronically-parked subscription is already visible/alertable via the parked
  # health dimension (aggregates + `[:ash_integration, :delivery, :parked]`
  # telemetry). Opting in lets a sustained parked backlog ALSO auto-suspend the
  # subscription — a DISTINCT "parked-suspend" that:
  #
  #   * is recoverable via `reprocess` + `unsuspend` (like every suspension), and
  #   * is its own dimension — not a transport/response failure, so it must not be
  #     conflated with the derived health suspend.
  #
  # Default OFF: a parked head already blocks only its own lane, so the conservative
  # default is purely visible/alertable with no auto-halt. Turn it on with:
  #
  #     config :ash_integration,
  #       parked_suspension: [enabled?: true, count_threshold: 50]

  @doc "Whether a sustained parked backlog auto-suspends the subscription. Default `false`."
  def parked_suspension_enabled? do
    Keyword.get(parked_suspension_config(), :enabled?, false)
  end

  @doc "Standing parked-delivery count that triggers the opt-in parked-suspend. Default `50`."
  def parked_suspension_threshold do
    Keyword.get(parked_suspension_config(), :count_threshold, 50)
  end

  defp parked_suspension_config do
    Keyword.get(config(), :parked_suspension, [])
  end

  def http_max_timeout_ms do
    Keyword.get(config(), :http_max_timeout_ms, 60_000)
  end

  @doc """
  Log level for the library's own internal poll/claim SQL — the housekeeping
  queries the dispatch relay, the delivery relay, and the scheduler issue on every
  poll tick (the outbox claim `UPDATE … RETURNING`, the `begin`/`commit` of the
  transaction that wraps it, and the scheduler's lane scan), whether or not there is
  work to do. On a busy *or idle* node these fire several times a second, so at the
  repo's default `:debug` level they can dominate the log.

  The value is passed straight through as Ecto's `:log` option — on both the claim
  query and its surrounding `Repo.transaction`, so the whole envelope is silenced,
  not just the query inside it. It accepts any `Logger` level (e.g. `:debug`,
  `:info`) or `false` to silence these queries entirely. Defaults to `:debug` —
  Ecto's own default, so behaviour is unchanged until you set it. Set
  `query_log_level: false` to stop the poll-loop query spam.

  The retention sweeper's bounded `DELETE`s (run once per `interval_ms`, default a
  minute) honour this too. They go through Ash (`Ash.bulk_destroy!`), which gives
  AshPostgres no per-query `:log` hook, so for that path the value is applied by
  scoping the sweeper process's `Logger` level around each delete rather than as
  Ecto's `:log`. The common cases match — `:debug` logs the delete, `false` silences
  it — but because a process level filters rather than re-emits, a level like `:info`
  *hides* the `:debug` delete instead of re-routing it to `:info`.

  Only the library's *internal* housekeeping queries honour this. Queries that run
  proportionally to real traffic (loading claimed rows, applying state transitions)
  are left at the repo default — they reflect actual work, not idle polling.
  """
  def query_log_level do
    Keyword.get(config(), :query_log_level, :debug)
  end

  # ── Retention stage ───────────────────────────────────────────────────────
  # The retention sweeper owns and validates its own configuration under the
  # nested `:retention` key — see `AshIntegration.Outbound.Retention` for the
  # schema, defaults, and windows. Not surfaced here (each stage owns its config).

  # ── Dispatch & delivery stages ────────────────────────────────────────────
  # Each pipeline stage owns and validates its own configuration under a nested key
  # — see `AshIntegration.Outbound.Dispatch.Supervisor` (`:dispatch`, incl. the opt-in
  # `max_dispatch_age_ms` give-up) and `AshIntegration.Outbound.Delivery.Supervisor`
  # (`:delivery`, incl. the opt-in `max_delivery_age_ms` give-up and the durable
  # backoff knobs). Neither stage has an attempt ceiling. They are intentionally NOT
  # surfaced here: this module doesn't become a god-module of every knob.
end
