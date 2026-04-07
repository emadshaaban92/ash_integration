defmodule AshIntegration.Transports.HttpTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Transports.Http

  describe "body_to_string/1" do
    test "returns binary body as-is" do
      assert Http.body_to_string("hello") == "hello"
      assert Http.body_to_string("") == ""
    end

    test "encodes map body as JSON" do
      result = Http.body_to_string(%{"key" => "value"})
      assert Jason.decode!(result) == %{"key" => "value"}
    end

    test "encodes list body as JSON" do
      result = Http.body_to_string([1, 2, 3])
      assert Jason.decode!(result) == [1, 2, 3]
    end

    test "falls back to inspect for non-encodable values" do
      result = Http.body_to_string({:tuple, :value})
      assert result =~ "tuple"
      assert result =~ "value"
    end
  end
end
