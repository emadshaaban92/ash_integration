ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Example.Repo, :manual)

# Mimic-copied modules so relay-producer tests can stub the outbox claim to simulate a
# transient DB blip mid-drain (see the outbound relay-producer tests).
Mimic.copy(AshIntegration.Outbound.Dispatch.Dispatcher)
Mimic.copy(AshIntegration.Outbound.Delivery.Dispatcher)
Mimic.copy(Ash)

# Copied so the delivery-relay tests can stub the transport boundary to crash
# (raise/exit/throw) and assert the batcher survives it (see "transport crash").
Mimic.copy(AshIntegration.Outbound.Wire.Transport)

# Under coverage, also instrument the :ash_integration dependency — the library
# under test, exercised only through this app. Plain `mix test` skips this.
if Process.whereis(:cover_server) do
  [Mix.Project.build_path(), "lib", "ash_integration", "ebin"]
  |> Path.join()
  |> String.to_charlist()
  |> :cover.compile_beam_directory()
end
