defmodule Mix.Tasks.AshIntegration.Events do
  @shortdoc "Lists the derived outbound event-type catalog"
  @moduledoc """
  Prints the event-first catalog derived from the configured `source_domains`.

  For each event type it lists the supported versions and the `(resource, action)`
  producers that contribute it.

      mix ash_integration.events
  """
  use Mix.Task

  alias AshIntegration.Outbound.Declare.Registry
  alias AshIntegration.Outbound.Declare.Source.Info

  @impl true
  def run(_args) do
    # Load config + compiled modules so resources can be enumerated.
    Mix.Task.run("app.config")

    catalog = Registry.catalog()

    if catalog == %{} do
      Mix.shell().info("No event types declared (check :ash_integration, :source_domains).")
    else
      catalog
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {event_type, %{versions: versions, producers: producers}} ->
        Mix.shell().info("\n#{IO.ANSI.bright()}#{event_type}#{IO.ANSI.reset()}")

        versions
        |> Enum.sort()
        |> Enum.each(fn version -> Mix.shell().info("  v#{version}") end)

        producers
        |> Enum.map(fn {resource, action} ->
          "#{Info.source_resource(resource)}.#{action}"
        end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.each(&Mix.shell().info("  ← #{&1}"))
      end)
    end
  end
end
