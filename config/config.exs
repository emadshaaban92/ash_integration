import Config

config :ash, :known_types, []
config :ash, :custom_types, []

config :ash_integration, :config, []
config :ash_integration, :vault, AshIntegration.TestVault

# Swoosh's SMTP adapter (gen_smtp) needs no HTTP API client, but the Microsoft
# Graph app-only email adapter sends over HTTP and requires one. Req is already a
# dependency, and the SMTP adapter ignores the api_client, so Req is safe for both
# paths. A host that only uses SMTP can override this back to `false`.
config :swoosh, :api_client, Swoosh.ApiClient.Req

import_config "#{config_env()}.exs"
