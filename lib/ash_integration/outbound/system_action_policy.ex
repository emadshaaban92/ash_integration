defmodule AshIntegration.Outbound.SystemActionPolicy do
  @moduledoc false
  # Defense-in-depth for the injected state-machine resources (the immutable Event
  # and the EventDelivery).
  #
  # The privileged internal state transitions (`:deliver`, `:record_failure`,
  # `:park`, `:reset_dispatch`) are driven ONLY by the library's own pipeline (the
  # dispatch/delivery relays, the scheduler, the Reprocessor), which runs them under
  # system authority (`authorize?: false`) — bypassing the authorizer entirely.
  # They are never meant to be invoked by an end-user/actor. But if a host exposes
  # one of these resources over an API extension (AshJsonApi / AshGraphql) or a code
  # interface, an actor-bearing call to one of these actions would be authorized by
  # whatever generic policy the host happens to have written for the resource.
  #
  # This injects a fail-closed policy that FORBIDS those actions for any actor-bearing
  # (authorized) call. Internal `authorize?: false` calls skip the authorizer and are
  # unaffected, so the pipeline keeps working; external actor-bearing callers are
  # denied by default. Combined with the host's own policies via AND (every policy
  # whose condition matches must pass), the `forbid_if always()` here always wins for
  # the guarded actions.
  #
  # Only applied when the host resource actually uses `Ash.Policy.Authorizer` —
  # otherwise there is no `policies` section to add to, and a host that opted out of
  # Ash authorization wholesale is making its own choice we can't (and shouldn't)
  # override by silently forcing the authorizer on.
  #
  # DELIBERATELY EXCLUDED: `:reprocess` and `:cancel`, though they are also system
  # transitions. The dashboard's operator gate authorizes them with
  # `Ash.can?({record, :reprocess | :cancel}, actor)` on those very actions —
  # force-denying them here would make that gate ALWAYS deny and break the (already
  # strict-gated) operator controls, and also the actor-authorized cancel/retry
  # updates. Locking those down too needs dedicated permission-proxy actions (the way
  # `:mark_dispatched` proxies the internal `:reset_dispatch` on Event), so the gate
  # and the guarded action are decoupled. Tracked as a follow-up.

  alias Spark.Dsl.Transformer

  @doc """
  Inject a `forbid_if always()` policy scoped to `actions` into `dsl_state`, so that
  every actor-bearing call to one of `actions` is denied. No-op unless the resource
  is authorized by `Ash.Policy.Authorizer`.
  """
  def deny(dsl_state, actions) when is_list(actions) do
    if Ash.Policy.Authorizer in Transformer.get_persisted(dsl_state, :authorizers, []) do
      Transformer.add_entity(dsl_state, [:policies], build_policy(actions), type: :append)
    else
      dsl_state
    end
  end

  defp build_policy(actions) do
    forbid =
      Transformer.build_entity!(Ash.Policy.Authorizer, [:policies, :policy], :forbid_if,
        check: Ash.Policy.Check.Builtins.always()
      )

    Transformer.build_entity!(Ash.Policy.Authorizer, [:policies], :policy,
      description: "ash_integration: internal state-machine action — system authority only",
      condition: Ash.Policy.Check.Builtins.action(actions),
      policies: [forbid]
    )
  end
end
