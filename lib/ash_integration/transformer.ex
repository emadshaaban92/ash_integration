defmodule AshIntegration.Transformer do
  @moduledoc false
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
        change: AshIntegration.Changes.PublishEvent,
        on: [:create, :update, :destroy]
      )

    {:ok, Transformer.add_entity(dsl_state, [:changes], change, type: :append)}
  end
end
