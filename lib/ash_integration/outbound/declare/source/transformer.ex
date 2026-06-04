defmodule AshIntegration.Outbound.Declare.Source.Transformer do
  @moduledoc false
  # Injects the change-capture hook onto the host resource. Injection MUST be
  # resource-local (Spark transformers are module-local), so it lives here.
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    {:ok, change} =
      Transformer.build_entity(Ash.Resource.Dsl, [:changes], :change,
        change: AshIntegration.Outbound.Capture.PublishEvent,
        on: [:create, :update, :destroy]
      )

    {:ok, Transformer.add_entity(dsl_state, [:changes], change, type: :append)}
  end
end
