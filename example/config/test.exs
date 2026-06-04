import Config
config :example, token_signing_secret: "yKpBZKMIc9DzUybshKt11cOyyArcE4XS"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :example, Example.Repo,
  username: "admin",
  password: "admin",
  hostname: "db",
  database: "example_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :example, ExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rdjqciemeeFhAG35Yc4Za6HlE7O6bAS7pjzFNumTaTQKQQqIVi8x041t6Fy0o2Gs",
  server: false

# The whole AshIntegration runtime is off in tests — no background relays, sweeper
# or scheduler. Each test starts exactly what it exercises (e.g. an isolated relay
# via `start_supervised!/1`, or the synchronous `drain_dispatch!`/`drain_delivery!`
# DataCase helpers), so the async Broadway pipelines never add nondeterminism or
# sandbox-ownership noise.
config :ash_integration, enabled?: false

# Route outbound delivery HTTP calls through Req.Test (owner = the HTTP transport
# that actually issues the request, now that the Oban delivery worker is gone).
config :ash_integration,
  req_options: [plug: {Req.Test, AshIntegration.Outbound.Wire.Transports.Http}]

# The SSRF egress guard resolves + checks delivery URLs. The suite delivers to
# loopback (`localhost:9999`, mocked by Req.Test), which the guard blocks by
# default — so turn it off here and exercise it explicitly in egress-specific
# tests (which flip `block_private?` back on for their scope).
config :ash_integration, egress: [block_private?: false]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
