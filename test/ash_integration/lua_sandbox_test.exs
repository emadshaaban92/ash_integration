defmodule AshIntegration.LuaSandboxTest do
  use ExUnit.Case, async: true

  alias AshIntegration.LuaSandbox

  describe "execute/2" do
    test "returns transformed result when script sets result" do
      script = ~S"""
      result = {name = event.name, doubled = event.count * 2}
      """

      event_data = %{"name" => "test", "count" => 5}
      assert {:ok, %{"name" => "test", "doubled" => 10}} = LuaSandbox.execute(script, event_data)
    end

    test "returns :skip when script does not set result" do
      script = ~S"""
      local x = 1 + 1
      """

      assert {:ok, :skip} = LuaSandbox.execute(script, %{})
    end

    test "rejects scripts exceeding maximum size" do
      script = String.duplicate("x", 10_241)

      assert {:error, "script exceeds maximum size of 10240 bytes"} =
               LuaSandbox.execute(script, %{})
    end

    test "returns error for Lua syntax errors" do
      script = "result = {"
      assert {:error, message} = LuaSandbox.execute(script, %{})
      assert is_binary(message)
    end

    test "returns error for Lua runtime errors" do
      script = ~S"""
      error("something went wrong")
      """

      assert {:error, message} = LuaSandbox.execute(script, %{})
      assert message =~ "something went wrong"
    end

    @tag timeout: 10_000
    test "returns error when script times out" do
      script = "while true do end"
      assert {:error, message} = LuaSandbox.execute(script, %{})
      assert message =~ "timed out"
    end

    test "event data round-trips through Lua" do
      script = "result = event"

      event_data = %{"id" => "abc", "nested" => %{"key" => "value"}}
      assert {:ok, result} = LuaSandbox.execute(script, event_data)
      assert result["id"] == "abc"
      assert result["nested"]["key"] == "value"
    end

    test "stringifies atom keys in event data" do
      script = "result = {got_name = event.name}"

      event_data = %{name: "test", details: %{status: "active"}}
      assert {:ok, %{"got_name" => "test"}} = LuaSandbox.execute(script, event_data)
    end

    test "Lua tables with string keys decode as maps" do
      script = ~S"""
      result = {foo = "bar", baz = "qux"}
      """

      assert {:ok, %{"foo" => "bar", "baz" => "qux"}} = LuaSandbox.execute(script, %{})
    end

    test "Lua sequential tables decode as integer-keyed tuples" do
      script = ~S"""
      result = {"a", "b", "c"}
      """

      assert {:ok, [{1, "a"}, {2, "b"}, {3, "c"}]} = LuaSandbox.execute(script, %{})
    end

    test "nested tables decode correctly" do
      script = ~S"""
      result = {
        items = {"x", "y"},
        meta = {count = 2}
      }
      """

      assert {:ok, result} = LuaSandbox.execute(script, %{})
      assert result["items"] == [{1, "x"}, {2, "y"}]
      assert result["meta"] == %{"count" => 2}
    end

    test "sandboxed functions raise runtime errors" do
      script = "os.exit(1)"
      assert {:error, _message} = LuaSandbox.execute(script, %{})
    end
  end
end
