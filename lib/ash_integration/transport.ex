defmodule AshIntegration.Transport do
  @moduledoc """
  Behaviour for outbound integration transports.

  Each transport receives the outbound integration record (with its
  transport_config loaded) and the JSON-encodable payload from the
  Lua transform, and returns a result that the OutboundDelivery worker
  logs.
  """

  @type success :: %{optional(atom()) => term()}
  @type error :: %{error_message: String.t(), retryable: boolean()}

  @callback deliver(
              outbound_integration :: struct(),
              event_id :: String.t(),
              resource_id :: String.t(),
              payload :: map()
            ) :: {:ok, success()} | {:error, error()}

  @spec module_for(atom()) :: module()
  def module_for(:http), do: AshIntegration.Transports.Http
  def module_for(:kafka), do: AshIntegration.Transports.Kafka
end
