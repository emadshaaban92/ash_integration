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
end
