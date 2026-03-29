spark_locals_without_parens = [
  resource_identifier: 1,
  loader: 1,
  supported_versions: 1,
  outbound_action: 1,
  ash_integration_dashboard: 1,
  ash_integration_dashboard: 2
]

[
  import_deps: [
    :ash,
    :ash_postgres,
    :ash_cloak,
    :ash_phoenix,
    :spark,
    :phoenix,
    :phoenix_live_view
  ],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
