defmodule AshIntegration.OutboundIntegrations.Loader do
  @moduledoc false

  @callback load_event(
              resource_id :: term(),
              action :: atom(),
              schema_version :: integer(),
              actor :: term(),
              occurred_at :: DateTime.t()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback sample_resource_id(actor :: term(), action :: atom()) ::
              {:ok, term()} | {:error, term()}
end
