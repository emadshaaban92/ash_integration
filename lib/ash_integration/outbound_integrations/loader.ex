defmodule AshIntegration.OutboundIntegrations.Loader do
  @moduledoc false

  @callback load_event_data(
              resource_id :: term(),
              action :: atom(),
              schema_version :: integer(),
              actor :: term()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback sample_resource_id(actor :: term(), action :: atom()) ::
              {:ok, term()} | {:error, term()}
  @callback sample_event_data(schema_version :: integer()) :: map()
end
