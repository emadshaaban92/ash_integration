defmodule AshIntegration.Outbound.Delivery.Log do
  @moduledoc """
  Persistence extension for an outbound **Log**: one row per delivery
  attempt of an event.

  Host applications attach this extension to their own resource and wire it via
  `config :ash_integration, delivery_log_resource: MyApp.Outbound.Log`.
  """

  use Spark.Dsl.Extension,
    transformers: [AshIntegration.Outbound.Delivery.Log.Transformer]
end
