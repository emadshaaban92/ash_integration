defmodule AshIntegration.Transport.SigningTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Transport.Signing

  describe "secret_state/1 (present-but-blank detection)" do
    test "a usable secret signs" do
      assert {:sign, "abc"} = Signing.secret_state("abc")
    end

    test "an empty or whitespace-only secret is :blank (present but unusable)" do
      assert :blank = Signing.secret_state("")
      assert :blank = Signing.secret_state("   ")
      assert :blank = Signing.secret_state("\t\n")
    end

    test "no secret is :none" do
      assert :none = Signing.secret_state(nil)
    end
  end

  describe "signature/2" do
    test "no signing secret → {:ok, nil} (unsigned, by design)" do
      assert {:ok, nil} = Signing.signature(%{signing_secret: nil}, "body")
    end
  end
end
