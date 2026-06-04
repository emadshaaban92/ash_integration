defmodule AshIntegration.TransportUtilsTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Transport.Utils

  describe "build_url/2" do
    test "returns the base URL unchanged for a nil or empty path" do
      assert Utils.build_url("https://api.example.com", nil) == "https://api.example.com"
      assert Utils.build_url("https://api.example.com", "") == "https://api.example.com"
    end

    test "joins base and path with exactly one slash regardless of surrounding slashes" do
      expected = "https://api.example.com/widgets"

      assert Utils.build_url("https://api.example.com", "/widgets") == expected
      assert Utils.build_url("https://api.example.com", "widgets") == expected
      assert Utils.build_url("https://api.example.com/", "/widgets") == expected
      assert Utils.build_url("https://api.example.com/", "widgets") == expected
    end

    test "preserves a base path on the connection" do
      assert Utils.build_url("https://api.example.com/v1", "/widgets") ==
               "https://api.example.com/v1/widgets"
    end
  end

  describe "load_secret/3" do
    # Regression guard for #76: every transport routes its credential/secret
    # decryption through here so that a decryption/vault failure becomes a
    # classified, NON-retryable :transport error instead of a raised MatchError
    # that escapes the {:error, %{failure_class: ...}} contract (which left the
    # Oban job crashing and retrying forever, never counting toward suspension).
    test "classifies a load that RAISES as a non-retryable transport failure" do
      assert {:error, %{failure_class: :transport, retryable: false} = error} =
               Utils.load_secret(%{not: "an ash record"}, [:token], "bearer token")

      assert error.error_message =~ "Failed to load bearer token"
    end

    test "labels the error with the given secret context" do
      assert {:error, %{error_message: message}} =
               Utils.load_secret(%{not: "an ash record"}, [:password], "Kafka SASL credentials")

      assert message =~ "Failed to load Kafka SASL credentials"
    end
  end
end
