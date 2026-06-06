ExUnit.start(exclude: [:kafka_integration])
Ecto.Adapters.SQL.Sandbox.mode(Example.Repo, :manual)

# When running under coverage (`mix coveralls` / `mix test --cover`), the built-in
# cover tool only instruments THIS app. The outbound runtime under test lives in
# the :ash_integration path dependency, which has no Repo of its own and is
# exercised exclusively through this example app. Cover-compile the dependency's
# beams as well (cover is already started here, so this only adds modules — it
# does not reset the example app's instrumentation) so the integration suite's
# real exercise of the library is reflected in the report. Plain `mix test`
# (no cover server) skips this entirely.
if Process.whereis(:cover_server) do
  ash_integration_ebin =
    Path.join([Mix.Project.build_path(), "lib", "ash_integration", "ebin"])

  ash_integration_ebin
  |> String.to_charlist()
  |> :cover.compile_beam_directory()
end
