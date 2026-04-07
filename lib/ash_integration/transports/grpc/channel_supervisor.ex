defmodule AshIntegration.Transports.Grpc.ChannelSupervisor do
  @moduledoc """
  Supervises per-integration gRPC channel processes.

  Each outbound integration gets its own `Channel` GenServer, started on
  demand via `DynamicSupervisor` and discoverable through a `Registry`.
  """

  use Supervisor

  @registry AshIntegration.Transports.Grpc.ChannelRegistry
  @dynamic_sup AshIntegration.Transports.Grpc.ChannelDynamicSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic_sup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Returns the registry name used for channel process lookups.
  """
  def registry, do: @registry

  @doc """
  Returns the DynamicSupervisor name used for starting channel processes.
  """
  def dynamic_supervisor, do: @dynamic_sup
end
