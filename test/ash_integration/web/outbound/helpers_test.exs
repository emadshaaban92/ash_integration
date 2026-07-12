defmodule AshIntegration.Web.Outbound.HelpersTest do
  @moduledoc """
  Pure view-helper logic — the filter/param plumbing and the header-loss detection
  that backs the connection form's warning banner. These have no data-layer or
  endpoint dependency, so they're cheap to keep honest.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Web.Outbound.Helpers

  describe "header_warnings/1" do
    test "warns when a row has a value but no name (it would be dropped on save)" do
      params = %{"transport_config" => %{"headers" => %{"1" => %{"key" => "", "value" => "v"}}}}
      assert Enum.any?(Helpers.header_warnings(params), &(&1 =~ "no name"))
    end

    test "warns when two rows share a name (only the last value survives)" do
      params = %{
        "transport_config" => %{
          "headers" => %{
            "1" => %{"key" => "X-Tenant", "value" => "a"},
            "2" => %{"key" => "X-Tenant", "value" => "b"}
          }
        }
      }

      assert Enum.any?(Helpers.header_warnings(params), &(&1 =~ "Duplicate"))
    end

    test "clean, distinct, named rows produce no warnings" do
      params = %{
        "transport_config" => %{
          "headers" => %{
            "1" => %{"key" => "X-A", "value" => "a"},
            "2" => %{"key" => "X-B", "value" => "b"}
          }
        }
      }

      assert Helpers.header_warnings(params) == []
    end

    test "also inspects the Kafka header editor" do
      params = %{
        "transport_config" => %{"headers_kafka" => %{"1" => %{"key" => "", "value" => "v"}}}
      }

      assert Enum.any?(Helpers.header_warnings(params), &(&1 =~ "Kafka header"))
    end

    test "no transport_config → no warnings" do
      assert Helpers.header_warnings(%{}) == []
    end
  end

  describe "filtered_path/2" do
    test "drops blank/zero params and query-encodes the rest" do
      path =
        Helpers.filtered_path("/deliveries",
          connection: "abc",
          state: nil,
          event_type: "",
          offset: 0
        )

      assert path == "/integrations/deliveries?connection=abc"
    end

    test "with nothing to add, returns the bare path" do
      assert Helpers.filtered_path("/deliveries", []) == "/integrations/deliveries"
    end
  end

  describe "presence/1 and parse_int/2" do
    test "presence collapses blank strings and nil to nil" do
      assert Helpers.presence("") == nil
      assert Helpers.presence(nil) == nil
      assert Helpers.presence("x") == "x"
    end

    test "parse_int parses, or returns the default on nil / garbage" do
      assert Helpers.parse_int("5", 0) == 5
      assert Helpers.parse_int(nil, 3) == 3
      assert Helpers.parse_int("nope", 7) == 7
      assert Helpers.parse_int(9, 0) == 9
    end
  end

  describe "format_datetime/2" do
    test "formats short and long, and renders a dash for non-datetimes" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-07-12T13:45:30Z")
      assert Helpers.format_datetime(dt) == "2026-07-12 13:45"
      assert Helpers.format_datetime(dt, :long) == "2026-07-12 13:45:30"
      assert Helpers.format_datetime(nil) == "—"
    end
  end
end
