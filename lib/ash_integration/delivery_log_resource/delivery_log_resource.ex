defmodule AshIntegration.DeliveryLogResource do
  use Spark.Dsl.Extension,
    transformers: [AshIntegration.DeliveryLogResource.Transformer]
end
