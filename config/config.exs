import Config

config :ash, :known_types, []
config :ash, :custom_types, []

# Ash 3.33 requires every app to say how string `min_length`/`max_length` are
# counted. `:codepoints` is Ash's recommendation and matches how SQL data layers
# count, so validation agrees with the database and `max_length` actually bounds
# the stored size (`:mixed`, the legacy behaviour, counts graphemes in Elixir, and
# a single grapheme can carry unboundedly many combining marks). Hosts set this
# for their own app; this is the suite's setting.
config :ash, :default_string_length_count, :codepoints

config :ash_integration, :config, []
config :ash_integration, :vault, AshIntegration.TestVault

# Swoosh's SMTP adapter (gen_smtp) needs no HTTP API client, but the Microsoft
# Graph app-only email adapter sends over HTTP and requires one. Req is already a
# dependency, and the SMTP adapter ignores the api_client, so Req is safe for both
# paths. A host that only uses SMTP can override this back to `false`.
config :swoosh, :api_client, Swoosh.ApiClient.Req

import_config "#{config_env()}.exs"
