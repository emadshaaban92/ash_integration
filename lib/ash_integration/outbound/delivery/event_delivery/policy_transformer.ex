defmodule AshIntegration.Outbound.Delivery.EventDelivery.PolicyTransformer do
  @moduledoc false
  # Runs LAST (after the main EventDelivery transformer has injected the actions and
  # after the resource's authorizers are persisted) to add the fail-closed
  # "system-authority only" policy for the internal delivery state transitions. See
  # `AshIntegration.Outbound.SystemActionPolicy` for the rationale and for why
  # `:reprocess`/`:cancel` are intentionally not included.
  use Spark.Dsl.Transformer

  alias AshIntegration.Outbound.SystemActionPolicy

  # Internal-only transitions with NO legitimate actor-bearing caller and which are
  # never used as an `Ash.can?` operator-gate subject — safe to hard-deny.
  @system_actions [:park, :deliver, :record_failure]

  @impl true
  def after?(_), do: true

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    {:ok, SystemActionPolicy.deny(dsl_state, @system_actions)}
  end
end
