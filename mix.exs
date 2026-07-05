defmodule AshIntegration.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/emadshaaban92/ash_integration"

  def project do
    [
      app: :ash_integration,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Tests define Ash resources at compile time, and each one carries its own
      # `Inspect` implementation. Consolidated protocols would make those runtime
      # implementations warn ("protocol has already been consolidated"), so leave
      # protocols unconsolidated in :test. See the Protocol module docs.
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      name: "AshIntegration",
      description: "Outbound integration system for Ash Framework with built-in dashboard UI",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      usage_rules: [
        file: "CLAUDE.md",
        usage_rules: ["usage_rules:all"],
        skills: [
          location: ".claude/skills",
          build: [
            "ash-framework": [
              description:
                "Use this skill when working with Ash Framework resources, actions, queries, authorization, calculations, aggregates, relationships, data layers, migrations, code interfaces, or any Ash extension (ash_postgres, ash_phoenix, ash_authentication).",
              usage_rules: [:ash, ~r/^ash_/]
            ],
            "phoenix-web": [
              description:
                "Use this skill when working with Phoenix controllers, LiveView, routes, Ecto schemas, HTML/HEEx templates, or Phoenix web layer code.",
              usage_rules: [:phoenix]
            ]
          ]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {AshIntegration.Application, []},
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
      {:broadway, "~> 1.0"},
      {:nimble_options, "~> 1.0"},
      {:req, "~> 0.5"},
      {:brod, "~> 4.0", optional: true},
      {:swoosh, "~> 1.0", optional: true},
      {:gen_smtp, "~> 1.0", optional: true},
      {:lua, "~> 0.4"},
      {:jason, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:live_select, "~> 1.0"},
      {:tidewave, "~> 0.1", only: [:dev]},
      {:simple_sat, "~> 0.1", only: [:test]},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
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
      extras: [
        "README.md",
        "guides/delivery-pipeline.md",
        "guides/observability.md",
        "guides/producers.md",
        "guides/http-transport.md",
        "guides/kafka-transport.md",
        "guides/email-transport.md",
        "guides/whatsapp-transport.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ]
    ]
  end
end
