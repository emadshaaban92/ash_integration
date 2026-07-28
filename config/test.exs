import Config

# `load_secret/3` resolves the configured domain to decrypt a stored secret
# (SMTP/SASL password). Point it at the test domain so transports that decrypt a
# credential (e.g. the email adapter config) can be exercised in the suite.
config :ash_integration, :domain, AshIntegration.Test.Domain

# The `datetime` host API exposed into the Lua sandbox resolves zones through the
# HOST's configured `Calendar.TimeZoneDatabase`. The library ships none (that is a
# host decision); the suite configures one so DST behaviour can be asserted for
# real. `tz` is a test/dev-only dependency.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
