defmodule AshIntegration.OutboundIntegrationResource do
  use Spark.Dsl.Extension,
    transformers: [AshIntegration.OutboundIntegrationResource.Transformer]
end
