# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :example,
  ecto_repos: [Example.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    Example.Accounts,
    Example.Catalog,
    Example.Integration
  ]

# Configure the endpoint
config :example, ExampleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ExampleWeb.ErrorHTML, json: ExampleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Example.PubSub,
  live_view: [signing_salt: "7J5v7s71"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.27.4",
  example: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.2.2",
  example: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :example, Example.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("dKxMxhOoEflIJC0hsaouaix7mVETmpMlVSpEBIifOiE=")}
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :ash_integration,
  otp_app: :example,
  outbound_integration_resource: Example.Integration.OutboundIntegration,
  outbound_integration_log_resource: Example.Integration.OutboundIntegrationLog,
  outbound_integration_event_resource: Example.Integration.OutboundIntegrationEvent,
  domain: Example.Integration,
  repo: Example.Repo,
  actor_resource: Example.Accounts.User,
  vault: Example.Vault

config :example, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.PG,
  queues: [
    integration_dispatch: 10,
    integration_delivery: 20,
    maintenance: 2
  ],
  repo: Example.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", AshIntegration.Workers.OutboundIntegrationLogCleanup}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
