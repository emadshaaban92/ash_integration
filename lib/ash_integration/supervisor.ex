defmodule AshIntegration.Supervisor do
  @moduledoc """
  Top-level supervisor for AshIntegration runtime processes.

  Add this to your application's supervision tree:

      children = [
        # ... your other children ...
        AshIntegration.Supervisor
      ]
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      AshIntegration.KafkaClientManager,
      AshIntegration.Transports.Grpc.ProtoRegistry
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
