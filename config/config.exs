import Config

config :ash, :known_types, []
config :ash, :custom_types, []

config :ash_integration, :config, []
config :ash_integration, :vault, AshIntegration.TestVault

# The email transport uses Swoosh's SMTP adapter (gen_smtp), never an HTTP API
# adapter, so Swoosh does not need an HTTP API client. Disabling it avoids
# Swoosh's boot-time requirement of a client library (hackney by default). A host
# that later adds a provider-API adapter can set its own `:api_client`.
config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
