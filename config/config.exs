import Config

config :ash, :known_types, []
config :ash, :custom_types, []

config :ash_integration, :config, []
config :ash_integration, :vault, AshIntegration.TestVault

import_config "#{config_env()}.exs"
