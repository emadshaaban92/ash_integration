defmodule AshIntegration.LuaHostAPIsTest do
  # Not async: both the host-API registry and the Calendar time-zone database are
  # global (application env), and these swap them.
  use ExUnit.Case, async: false

  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua

  # The realistic near-miss: a real, loadable module that exports `scope/0` for
  # its own reasons but never did `use Lua.API`, so it has no `__lua_functions__/0`
  # for `Lua.load_api/2` to read.
  defmodule NotQuiteALuaAPI do
    def scope, do: ["myapp"]
  end

  defp put_sandbox_config(config) do
    original = Application.get_env(:ash_integration, :lua_sandbox)
    Application.put_env(:ash_integration, :lua_sandbox, config)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_integration, :lua_sandbox)
        value -> Application.put_env(:ash_integration, :lua_sandbox, value)
      end
    end)
  end

  defp run(body, event \\ %{}) do
    Lua.execute("function transform(event, defaults)\n#{body}\nend", event)
  end

  describe "host-registered APIs" do
    test "a configured API module is callable from a transform" do
      put_sandbox_config(apis: [AshIntegration.Test.LuaAPI])

      assert {:ok, %{"shouted" => "SHIP IT!", "path" => "/t/acme/orders/42"}} =
               run(
                 ~S"""
                 return {
                   shouted = myapp.shout(event.msg),
                   path = myapp.tenant_path("acme", event.id)
                 }
                 """,
                 %{"msg" => "ship it", "id" => "42"}
               )

      assert {:ok, %{"shouted" => "SHIP IT!"}} =
               run(~S|return {shouted = myapp.shout("ship it")}|)
    end

    test "the built-in datetime API is still loaded alongside a host's own" do
      put_sandbox_config(apis: [AshIntegration.Test.LuaAPI])

      assert {:ok, %{"at" => "2024-06-15T13:30:00+03:00", "shouted" => "HI!"}} =
               run(~S"""
               return {
                 at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo"),
                 shouted = myapp.shout("hi")
               }
               """)
    end

    test "host APIs are loaded into signing sessions too" do
      put_sandbox_config(apis: [AshIntegration.Test.LuaAPI])

      source = ~S|function string_to_sign(ctx) return myapp.shout(ctx.body) end|

      assert {:ok, {:defined, "PAYLOAD!"}} =
               Lua.sign_session(source, Lua.default_limits(), fn call ->
                 call.("string_to_sign", %{"body" => "payload"})
               end)
    end

    test "with no :apis configured, only the built-ins load" do
      put_sandbox_config(timeout_ms: 5_000)

      assert {:ok, %{"at" => "2024-06-15T13:30:00+03:00"}} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)

      assert {:error, _} = run(~S|return {shouted = myapp.shout("hi")}|)
    end

    test "a module that is not a Lua API parks with a legible message" do
      put_sandbox_config(apis: [NotAnAPIModule])

      assert {:error, message} = run(~S|return {ok = true}|)
      assert message =~ "could not load the configured Lua host APIs"
      assert message =~ "NotAnAPIModule"
      assert message =~ "use Lua.API"
    end

    test "a real module that only looks like a Lua API parks with the same message" do
      put_sandbox_config(apis: [NotQuiteALuaAPI])

      assert {:error, message} = run(~S|return {ok = true}|)
      assert message =~ "could not load the configured Lua host APIs"
      assert message =~ "NotQuiteALuaAPI"
      assert message =~ "use Lua.API"
      # Not the raw UndefinedFunctionError from inside Lua.load_api/2.
      refute message =~ "__lua_functions__"
    end

    test "a misconfigured API also fails a signing session legibly" do
      put_sandbox_config(apis: [NotAnAPIModule])

      assert {:error, message} =
               Lua.sign_session(
                 ~S|function string_to_sign(ctx) return "x" end|,
                 Lua.default_limits(),
                 fn call -> call.("string_to_sign", %{}) end
               )

      assert message =~ "could not load the configured Lua host APIs"
    end

    test "a raising host API surfaces its message and parks, like the built-in does" do
      put_sandbox_config(apis: [AshIntegration.Test.LuaAPI])

      assert {:error, message} = run(~S|return {x = myapp.explode("on purpose")}|)
      assert message =~ "host API blew up: on purpose"

      # The sandbox is usable immediately afterwards.
      assert {:ok, %{"shouted" => "OK!"}} = run(~S|return {shouted = myapp.shout("ok")}|)
    end
  end

  describe "a host scope that collides with a built-in" do
    test "REPLACES the built-in wholesale rather than merging with it" do
      put_sandbox_config(apis: [AshIntegration.Test.CollidingLuaAPI])

      # The host's own function is there...
      assert {:ok, %{"day" => day}} =
               run(~S|return {day = datetime.epoch_day("2024-06-15T10:30:00Z")}|)

      assert is_number(day)

      # ...and the built-in's are gone, because `Lua.load_api/2` resets the scope
      # table. This is the behaviour the boot check warns about.
      assert {:error, message} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)

      assert message =~ "undefined function"
    end

    test "the built-in is intact again once the colliding API is unconfigured" do
      put_sandbox_config([])

      assert {:ok, %{"at" => "2024-06-15T13:30:00+03:00"}} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)
    end
  end

  describe "boot check" do
    import ExUnit.CaptureLog

    test "warns about an unloadable :apis entry" do
      put_sandbox_config(apis: [NotQuiteALuaAPI, NoSuchModuleAtAll])

      log = capture_log(fn -> assert :ok = Lua.warn_about_host_apis() end)

      assert log =~ "NotQuiteALuaAPI"
      assert log =~ "NoSuchModuleAtAll"
      assert log =~ "use Lua.API"
    end

    test "warns that a colliding scope replaces the built-in, naming what is lost" do
      put_sandbox_config(apis: [AshIntegration.Test.CollidingLuaAPI])

      log = capture_log(fn -> assert :ok = Lua.warn_about_host_apis() end)

      assert log =~ "CollidingLuaAPI"
      assert log =~ "REPLACES"
      # The functions that actually disappear, not a hand-written list.
      assert log =~ "datetime.to_zone"
      assert log =~ "datetime.format"
    end

    test "stays quiet for a valid configuration" do
      put_sandbox_config(apis: [AshIntegration.Test.LuaAPI])

      assert capture_log(fn -> assert :ok = Lua.warn_about_host_apis() end) == ""
    end

    test "stays quiet when no :apis are configured" do
      put_sandbox_config(timeout_ms: 5_000)

      assert capture_log(fn -> assert :ok = Lua.warn_about_host_apis() end) == ""
    end
  end

  describe "no time-zone database configured" do
    setup do
      original = Calendar.get_time_zone_database()
      Calendar.put_time_zone_database(Calendar.UTCOnlyTimeZoneDatabase)
      on_exit(fn -> Calendar.put_time_zone_database(original) end)
      :ok
    end

    test "the delivery parks naming utc_only_time_zone_database, never silently emitting UTC" do
      assert {:error, message} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)

      assert message =~ "utc_only_time_zone_database"
      assert message =~ "time_zone_database"
      refute message =~ "13:30"
    end

    test "datetime.format fails the same way" do
      assert {:error, message} =
               run(
                 ~S|return {at = datetime.format("2024-06-15T10:30:00Z", "Africa/Cairo", "%H:%M")}|
               )

      assert message =~ "utc_only_time_zone_database"
    end

    test "Etc/UTC still works without a database" do
      assert {:ok, %{"at" => "2024-06-15 10:30"}} =
               run(
                 ~S|return {at = datetime.format("2024-06-15T10:30:00Z", "Etc/UTC", "%Y-%m-%d %H:%M")}|
               )
    end
  end
end
