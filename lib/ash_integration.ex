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
          concurrency:      System.schedulers_online(),
          poll_interval_ms: 250,
          batch_size:       100,
          max_attempts:     20
        ],
        delivery: [
          concurrency:      25,
          poll_interval_ms: 250,
          batch_size:       100,
          max_attempts:     20,
          backoff_base_ms:    1_000,
          backoff_max_ms:   300_000
        ],
        retention: [
          interval_ms:   :timer.minutes(1),
          delete_limit:  500,
          delivery_days: 90,
          event_days:    365
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

  def auto_suspension_threshold do
    Keyword.get(config(), :auto_suspension_threshold, 50)
  end

  def http_max_timeout_ms do
    Keyword.get(config(), :http_max_timeout_ms, 60_000)
  end

  @doc """
  Log level for the library's own internal poll/claim SQL — the housekeeping
  queries the dispatch relay, the delivery relay, and the scheduler issue on every
  poll tick (the outbox claim `UPDATE … RETURNING` and the scheduler's lane scan),
  whether or not there is work to do. On a busy *or idle* node these fire several
  times a second, so at the repo's default `:debug` level they can dominate the log.

  The value is passed straight through as Ecto's `:log` option, so it accepts any
  `Logger` level (e.g. `:debug`, `:info`) or `false` to silence these queries
  entirely. Defaults to `:debug` — Ecto's own default, so behaviour is unchanged
  until you set it. Set `query_log_level: false` to stop the poll-loop query spam.

  Only the library's high-frequency *internal* queries honour this. Queries that run
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
  # — see `AshIntegration.Outbound.Dispatch.Supervisor` (`:dispatch`) and
  # `AshIntegration.Outbound.Delivery.Supervisor` (`:delivery`, which also owns the
  # delivery poison ceiling `max_attempts` and the durable backoff knobs). They are
  # intentionally NOT surfaced here: this module doesn't become a god-module of every
  # knob.
end
