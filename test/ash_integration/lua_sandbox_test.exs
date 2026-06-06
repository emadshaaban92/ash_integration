defmodule AshIntegration.LuaSandboxTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua

  describe "execute/2" do
    test "returns the value the exposed transform returns" do
      script = ~S"""
      function transform(event, defaults)
        return {name = event.name, doubled = event.count * 2}
      end
      """

      event_data = %{"name" => "test", "count" => 5}
      assert {:ok, %{"name" => "test", "doubled" => 10}} = Lua.execute(script, event_data)
    end

    test "returns :skip when the source exposes no transform (and no defaults)" do
      script = ~S"""
      local x = 1 + 1
      """

      assert {:ok, :skip} = Lua.execute(script, %{})
    end

    test "returns :skip when transform returns nil" do
      script = ~S"""
      function transform(event, defaults)
        return nil
      end
      """

      assert {:ok, :skip} = Lua.execute(script, %{})
    end

    test "passes the defaults through unchanged when no transform is defined" do
      assert {:ok, %{"method" => "post"}} =
               Lua.execute("-- no-op", %{}, defaults: %{"method" => "post"})
    end

    test "rejects scripts exceeding maximum size" do
      script = String.duplicate("x", 10_241)

      assert {:error, "script exceeds maximum size of 10240 bytes"} =
               Lua.execute(script, %{})
    end

    test "returns error for Lua syntax errors" do
      script = "function transform(event, defaults) return {"
      assert {:error, message} = Lua.execute(script, %{})
      assert is_binary(message)
    end

    test "returns error for Lua runtime errors" do
      script = ~S"""
      function transform(event, defaults)
        error("something went wrong")
      end
      """

      assert {:error, message} = Lua.execute(script, %{})
      assert message =~ "something went wrong"
    end

    @tag timeout: 10_000
    test "returns error when a script runs away (reduction budget or wall-clock)" do
      script = ~S"""
      function transform(event, defaults)
        while true do end
      end
      """

      assert {:error, message} = Lua.execute(script, %{})
      assert message =~ "reduction" or message =~ "timed out"
    end

    test "event data round-trips through Lua" do
      script = ~S"""
      function transform(event, defaults)
        return event
      end
      """

      event_data = %{"id" => "abc", "nested" => %{"key" => "value"}}
      assert {:ok, result} = Lua.execute(script, event_data)
      assert result["id"] == "abc"
      assert result["nested"]["key"] == "value"
    end

    test "stringifies atom keys in event data" do
      script = ~S"""
      function transform(event, defaults)
        return {got_name = event.name}
      end
      """

      event_data = %{name: "test", details: %{status: "active"}}
      assert {:ok, %{"got_name" => "test"}} = Lua.execute(script, event_data)
    end

    test "Lua tables with string keys decode as maps" do
      script = ~S"""
      function transform(event, defaults)
        return {foo = "bar", baz = "qux"}
      end
      """

      assert {:ok, %{"foo" => "bar", "baz" => "qux"}} = Lua.execute(script, %{})
    end

    test "Lua sequential tables decode as ordered lists" do
      script = ~S"""
      function transform(event, defaults)
        return {"a", "b", "c"}
      end
      """

      assert {:ok, ["a", "b", "c"]} = Lua.execute(script, %{})
    end

    test "Lua arrays of objects decode as a list of maps" do
      script = ~S"""
      function transform(event, defaults)
        return {
          {id = 1, name = "a"},
          {id = 2, name = "b"}
        }
      end
      """

      assert {:ok, [%{"id" => 1, "name" => "a"}, %{"id" => 2, "name" => "b"}]} =
               Lua.execute(script, %{})
    end

    test "sequence order is preserved regardless of insertion order" do
      script = ~S"""
      function transform(event, defaults)
        local r = {}
        r[3] = "third"
        r[1] = "first"
        r[2] = "second"
        return r
      end
      """

      assert {:ok, ["first", "second", "third"]} = Lua.execute(script, %{})
    end

    test "empty Lua table decodes as empty list" do
      script = ~S"""
      function transform(event, defaults)
        return {}
      end
      """

      assert {:ok, []} = Lua.execute(script, %{})
    end

    test "nested tables decode correctly" do
      script = ~S"""
      function transform(event, defaults)
        return {
          items = {"x", "y"},
          meta = {count = 2}
        }
      end
      """

      assert {:ok, result} = Lua.execute(script, %{})
      assert result["items"] == ["x", "y"]
      assert result["meta"] == %{"count" => 2}
    end

    test "objects nested inside sequences decode recursively" do
      script = ~S"""
      function transform(event, defaults)
        return {
          rows = {
            {sku = "A", qty = 1},
            {sku = "B", qty = 2}
          }
        }
      end
      """

      assert {:ok, result} = Lua.execute(script, %{})

      assert result["rows"] == [
               %{"sku" => "A", "qty" => 1},
               %{"sku" => "B", "qty" => 2}
             ]
    end

    test "sandboxed functions raise runtime errors" do
      script = ~S"""
      function transform(event, defaults)
        os.exit(1)
      end
      """

      assert {:error, _message} = Lua.execute(script, %{})
    end
  end
end
