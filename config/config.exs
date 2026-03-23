import Config

config :ash, :known_types, []
config :ash, :custom_types, []

config :ash_integration, :config, []

import_config "#{config_env()}.exs"
