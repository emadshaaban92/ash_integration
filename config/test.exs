import Config

# `load_secret/3` resolves the configured domain to decrypt a stored secret
# (SMTP/SASL password). Point it at the test domain so transports that decrypt a
# credential (e.g. the email adapter config) can be exercised in the suite.
config :ash_integration, :domain, AshIntegration.Test.Domain
