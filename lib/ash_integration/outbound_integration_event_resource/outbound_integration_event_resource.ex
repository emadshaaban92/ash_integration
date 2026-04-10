defmodule AshIntegration.OutboundIntegrationEventResource do
  use Spark.Dsl.Extension,
    transformers: [AshIntegration.OutboundIntegrationEventResource.Transformer]
end
