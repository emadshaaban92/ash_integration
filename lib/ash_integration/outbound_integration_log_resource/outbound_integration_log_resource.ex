defmodule AshIntegration.OutboundIntegrationLogResource do
  use Spark.Dsl.Extension,
    transformers: [AshIntegration.OutboundIntegrationLogResource.Transformer]
end
