defmodule AshIntegration.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/emadshaaban92/ash_integration"

  def project do
    [
      app: :ash_integration,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "AshIntegration",
      description: "Outbound integration system for Ash Framework with built-in dashboard UI",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_cloak, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:spark, "~> 2.0"},
      {:oban, "~> 2.0"},
      {:req, "~> 0.5"},
      {:lua, "~> 0.4"},
      {:jason, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:live_select, "~> 1.0"},
      {:tidewave, "~> 0.1", only: [:dev]},
      {:simple_sat, "~> 0.1", only: [:test]},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
