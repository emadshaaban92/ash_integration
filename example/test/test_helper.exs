ExUnit.start(exclude: [:kafka_integration])
Ecto.Adapters.SQL.Sandbox.mode(Example.Repo, :manual)

# Under coverage, also instrument the :ash_integration dependency — the library
# under test, exercised only through this app. Plain `mix test` skips this.
if Process.whereis(:cover_server) do
  [Mix.Project.build_path(), "lib", "ash_integration", "ebin"]
  |> Path.join()
  |> String.to_charlist()
  |> :cover.compile_beam_directory()
end
