defmodule AshIntegration.Web.Outbound.HelpersCanTest do
  @moduledoc """
  `can?/2` is the UI's authorization gate. It must be **fail-closed**: any error
  resolving the check renders as `false`, so the UI never offers an action the
  host's policies would reject (and never crashes a render). The happy path —
  passing the real `Ash.can?` decision through — is exercised by the example
  app's tests, which run under real policies.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Web.Outbound.Helpers

  test "denies (fail-closed) when the check cannot be resolved" do
    refute Helpers.can?(:not_a_valid_subject, %{id: "actor"})
    refute Helpers.can?({NotARealResource, :create}, nil)
    refute Helpers.can?(nil, nil)
  end

  describe "can_strict?/2 — the privileged operator gate" do
    # `RecordScopedUpdate`'s `:touch` policy is a data-dependent filter
    # (`owner_id == ^actor(:id)`). A resource-level check can't be decided without
    # the row, so `Ash.can?` resolves it to `:maybe` — exactly the record-scoped
    # policy shape ("only deliveries of connections you own") the operator gates
    # must NOT treat as a grant.
    @indeterminate {AshIntegration.Test.RecordScopedUpdate, :touch}

    test "an indeterminate (:maybe) policy DENIES, where the permissive can?/2 grants" do
      actor = %{id: "someone"}

      # Permissive default (`maybe_is: true`) — the leak: everyone is granted.
      assert Helpers.can?(@indeterminate, actor)
      # Strict (`maybe_is: false`) — fails closed on the indeterminate policy.
      refute Helpers.can_strict?(@indeterminate, actor)
    end

    test "a definite authorization still passes (no regression for a permitted actor)" do
      # `Parent`'s policy is `authorize_if always()` → a definite grant.
      assert Helpers.can_strict?({AshIntegration.Test.Parent, :read}, %{id: "a"})
    end

    test "denies (fail-closed) when the check cannot be resolved" do
      refute Helpers.can_strict?(:not_a_valid_subject, %{id: "actor"})
      refute Helpers.can_strict?({NotARealResource, :create}, nil)
      refute Helpers.can_strict?(nil, nil)
    end
  end
end
