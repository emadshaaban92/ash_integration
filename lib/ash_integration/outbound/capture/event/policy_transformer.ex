defmodule AshIntegration.Outbound.Capture.Event.PolicyTransformer do
  @moduledoc false
  # Runs LAST (after the main Event transformer has injected the actions and after
  # the resource's authorizers are persisted) to add the fail-closed
  # "system-authority only" policy for the internal outbox transition. See
  # `AshIntegration.Outbound.SystemActionPolicy` for the rationale.
  #
  # `:reset_dispatch` is the library-internal un-poison write (driven by the operator
  # dashboard under `authorize?: false`, gated on the separate `:mark_dispatched`
  # permission) — so hard-denying `:reset_dispatch` for actor-bearing callers does
  # not break the operator gate. `:expire_dispatch` is the library-internal terminal
  # write (driven only by the age sweep under `authorize?: false`), never an
  # actor-facing action — so it is hard-denied for authorized callers too.
  use Spark.Dsl.Transformer

  alias AshIntegration.Outbound.SystemActionPolicy

  @system_actions [:reset_dispatch, :expire_dispatch]

  @impl true
  def after?(_), do: true

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    {:ok, SystemActionPolicy.deny(dsl_state, @system_actions)}
  end
end
