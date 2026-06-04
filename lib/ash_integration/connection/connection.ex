defmodule AshIntegration.Connection do
  @moduledoc """
  Persistence extension for an outbound **Connection**: where and how events
  are delivered (transport + auth + signing) and the ordering domain. A
  connection fans out to many subscriptions and is reusable across them.

  This is a Spark DSL extension the host application attaches to its own
  resource; the host names the module and table and wires it via
  `config :ash_integration, connection_resource: MyApp.Outbound.Connection`.
  Health fields (`active`/`suspended`/`consecutive_failures`) are fed by
  transport failures.
  """

  use Spark.Dsl.Extension,
    transformers: [AshIntegration.Connection.Transformer]
end
