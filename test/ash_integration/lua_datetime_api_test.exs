defmodule AshIntegration.LuaDatetimeAPITest do
  # The suite configures `Tz.TimeZoneDatabase` (config/test.exs), so these read
  # real zone rules and never touch global state.
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Delivery.Transform.Runtime.Lua

  defp run(body, event \\ %{}) do
    Lua.execute("function transform(event, defaults)\n#{body}\nend", event)
  end

  describe "datetime.to_zone/2" do
    test "renders the instant with the zone's offset" do
      assert {:ok, %{"at" => "2024-06-15T13:30:00+03:00"}} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)
    end

    test "reads the timestamp off the event envelope" do
      assert {:ok, %{"at" => "2024-03-01T12:00:00+01:00"}} =
               run(
                 ~S|return {at = datetime.to_zone(event.created_at, "Europe/Berlin")}|,
                 %{"created_at" => "2024-03-01T11:00:00Z"}
               )
    end

    test "accepts an input that already carries a non-UTC offset" do
      assert {:ok, %{"at" => "2024-06-15T06:30:00-04:00"}} =
               run(
                 ~S|return {at = datetime.to_zone("2024-06-15T13:30:00+03:00", "America/New_York")}|
               )
    end

    test "converting to the zone the input is already in is a no-op" do
      assert {:ok, %{"at" => "2024-06-15T10:30:00Z"}} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Etc/UTC")}|)
    end
  end

  describe "DST correctness" do
    # The whole point of the API: a hardcoded "+02:00" is wrong for half the year
    # in any DST region. Egypt observes DST again since 2023.
    test "Africa/Cairo is +02:00 in January and +03:00 in June" do
      assert {:ok, %{"winter" => winter, "summer" => summer}} =
               run(~S"""
               return {
                 winter = datetime.to_zone("2024-01-15T10:30:00Z", "Africa/Cairo"),
                 summer = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")
               }
               """)

      assert winter == "2024-01-15T12:30:00+02:00"
      assert summer == "2024-06-15T13:30:00+03:00"
    end

    test "the offset flips across the transition instant, not the calendar month" do
      # Egypt's 2024 DST started Fri 2024-04-26 at 00:00 local (21:00Z Apr 25).
      assert {:ok,
              %{"before" => "2024-04-25T22:00:00+02:00", "after" => "2024-04-26T01:00:00+03:00"}} =
               run(~S"""
               return {
                 before = datetime.to_zone("2024-04-25T20:00:00Z", "Africa/Cairo"),
                 after  = datetime.to_zone("2024-04-25T22:00:00Z", "Africa/Cairo")
               }
               """)
    end

    test "%z / %Z reflect the DST offset and abbreviation" do
      assert {:ok, %{"winter" => "+0200 EET", "summer" => "+0300 EEST"}} =
               run(~S"""
               return {
                 winter = datetime.format("2024-01-15T10:30:00Z", "Africa/Cairo", "%z %Z"),
                 summer = datetime.format("2024-06-15T10:30:00Z", "Africa/Cairo", "%z %Z")
               }
               """)
    end
  end

  describe "datetime.format/3" do
    test "formats with Calendar.strftime directives in the target zone" do
      assert {:ok, %{"at" => "2024-06-15 13:30:00"}} =
               run(
                 ~S|return {at = datetime.format("2024-06-15T10:30:00Z", "Africa/Cairo", "%Y-%m-%d %H:%M:%S")}|
               )
    end

    test "supports textual directives" do
      assert {:ok, %{"at" => "Saturday, 15 June 2024"}} =
               run(
                 ~S|return {at = datetime.format("2024-06-15T10:30:00Z", "Africa/Cairo", "%A, %d %B %Y")}|
               )
    end

    test "a format string with no directives passes through" do
      assert {:ok, %{"at" => "delivered"}} =
               run(
                 ~S|return {at = datetime.format("2024-06-15T10:30:00Z", "Etc/UTC", "delivered")}|
               )
    end
  end

  describe "failures park the delivery instead of emitting a wrong timestamp" do
    test "an unknown zone raises, naming the zone" do
      assert {:error, message} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Mars/Olympus")}|)

      assert message =~ "unknown time zone"
      assert message =~ "Mars/Olympus"
      assert message =~ "datetime.to_zone()"
    end

    test "an unparseable timestamp raises" do
      assert {:error, message} = run(~S|return {at = datetime.to_zone("yesterday", "Etc/UTC")}|)
      assert message =~ "not a valid ISO-8601 timestamp"
    end

    test "a timestamp with no UTC offset raises rather than assuming UTC" do
      assert {:error, message} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00", "Africa/Cairo")}|)

      assert message =~ "has no UTC offset"
    end

    test "an invalid strftime directive raises" do
      assert {:error, message} =
               run(~S|return {at = datetime.format("2024-06-15T10:30:00Z", "Etc/UTC", "%Q")}|)

      assert message =~ "invalid format string"
    end

    test "a non-string format string raises" do
      assert {:error, message} =
               run(~S|return {at = datetime.format("2024-06-15T10:30:00Z", "Etc/UTC", 5)}|)

      assert message =~ "expected a format string"
    end

    test "non-string arguments raise" do
      assert {:error, message} = run(~S|return {at = datetime.to_zone(1718447400, "Etc/UTC")}|)
      assert message =~ "expected an ISO-8601 timestamp string"

      assert {:error, message} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", 2)}|)

      assert message =~ "expected a time zone name string"
    end

    test "the wrong number of arguments raises" do
      assert {:error, message} = run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z")}|)
      assert message =~ "expected 2 arguments"
    end

    test "a raising host call parks the delivery, leaving the sandbox usable" do
      assert {:error, _} = run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Nope")}|)

      assert {:ok, %{"at" => "2024-06-15T13:30:00+03:00"}} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)
    end
  end

  describe "state isolation" do
    test "a script that shadows datetime hurts only its own run" do
      assert {:ok, %{"at" => "clobbered"}} =
               run(~S"""
               datetime = {to_zone = function(a, b) return "clobbered" end}
               return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}
               """)

      # Every run builds a fresh Lua.new/0 and re-loads the APIs into it, so the
      # next execution sees the real one.
      assert {:ok, %{"at" => "2024-06-15T13:30:00+03:00"}} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)
    end

    test "a script that nils out datetime cannot break the next run" do
      assert {:error, _} =
               run(~S"""
               datetime = nil
               return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}
               """)

      assert {:ok, %{"at" => "2024-06-15T13:30:00+03:00"}} =
               run(~S|return {at = datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")}|)
    end
  end

  describe "scripts that use none of it" do
    test "a no-op source still passes the pre-seeded defaults through" do
      assert {:ok, %{"method" => "post", "path" => "/hooks"}} =
               Lua.execute("-- nothing here", %{},
                 defaults: %{"method" => "post", "path" => "/hooks"}
               )
    end

    test "an ordinary transform is unaffected by the loaded APIs" do
      assert {:ok, %{"body" => %{"id" => "abc"}, "headers" => %{"x-event-id" => "e1"}}} =
               Lua.execute(
                 ~S"""
                 function transform(event, defaults)
                   defaults.body = {id = event.id}
                   return defaults
                 end
                 """,
                 %{"id" => "abc"},
                 defaults: %{"headers" => %{"x-event-id" => "e1"}}
               )
    end

    test "a global named datetime in the author's own script is still theirs" do
      assert {:ok, %{"got" => "mine"}} =
               run(~S"""
               local datetime = "mine"
               return {got = datetime}
               """)
    end
  end

  describe "signing sessions" do
    test "signing callbacks get the same utilities" do
      source = ~S"""
      function string_to_sign(ctx)
        return datetime.format(ctx.timestamp, "Etc/UTC", "%Y%m%dT%H%M%SZ") .. "\n" .. ctx.body
      end
      """

      assert {:ok, {:defined, "20240615T103000Z\n{}"}} =
               Lua.sign_session(source, Lua.default_limits(), fn call ->
                 call.("string_to_sign", %{"timestamp" => "2024-06-15T10:30:00Z", "body" => "{}"})
               end)
    end

    test "a raising host call in a signing callback surfaces a legible error" do
      source = ~S"""
      function string_to_sign(ctx)
        return datetime.to_zone(ctx.timestamp, "Mars/Olympus")
      end
      """

      assert {:error, message} =
               Lua.sign_session(source, Lua.default_limits(), fn call ->
                 call.("string_to_sign", %{"timestamp" => "2024-06-15T10:30:00Z"})
               end)

      assert message =~ "unknown time zone"
    end
  end
end
