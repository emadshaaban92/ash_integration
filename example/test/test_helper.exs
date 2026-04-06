ExUnit.start(exclude: [:kafka_integration, :grpc_integration])
Ecto.Adapters.SQL.Sandbox.mode(Example.Repo, :manual)
