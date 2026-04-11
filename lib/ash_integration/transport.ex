defmodule AshIntegration.Transport do
  @moduledoc """
  Behaviour for outbound integration transports.

  Each transport receives the outbound integration record (with its
  transport_config loaded) and the JSON-encodable payload from the
  Lua transform, and returns a result that the OutboundDelivery worker
  logs.

  ## Transport Availability

  HTTP is always available. Kafka and gRPC are optional:

    * **Kafka** — requires the `:brod` dependency
    * **gRPC** *(experimental)* — requires the `:protobuf` dependency plus
      `grpcurl` and `protoc` executables on PATH

  Use `available/0` or `available?/1` to check at runtime.
  """

  @type success :: %{optional(atom()) => term()}
  @type error :: %{error_message: String.t(), retryable: boolean()}

  @callback deliver(
              outbound_integration :: struct(),
              event_id :: String.t(),
              resource_id :: String.t(),
              payload :: map()
            ) :: {:ok, success()} | {:error, error()}

  @doc """
  Returns the list of transport types available in this environment.

  HTTP is always included. Kafka appears when `:brod` is loaded.
  gRPC appears when `:protobuf` is loaded and both `grpcurl` and `protoc`
  are on PATH.
  """
  @spec available() :: [:http | :kafka | :grpc]
  def available do
    [:http] ++
      if(kafka_available?(), do: [:kafka], else: []) ++
      if(grpc_available?(), do: [:grpc], else: [])
  end

  @doc """
  Returns `true` if the given transport type is available.
  """
  @spec available?(atom()) :: boolean()
  def available?(:http), do: true
  def available?(:kafka), do: kafka_available?()
  def available?(:grpc), do: grpc_available?()
  def available?(_), do: false

  @doc false
  def kafka_available? do
    Code.ensure_loaded?(:brod)
  end

  @doc false
  def grpc_available? do
    Code.ensure_loaded?(Google.Protobuf.FileDescriptorSet) &&
      System.find_executable("grpcurl") != nil &&
      System.find_executable("protoc") != nil
  end

  @spec module_for(atom()) :: module()
  def module_for(:http), do: AshIntegration.Transports.Http
  def module_for(:kafka), do: AshIntegration.Transports.Kafka
  def module_for(:grpc), do: AshIntegration.Transports.Grpc
end
