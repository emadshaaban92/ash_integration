defmodule AshIntegration.TelemetryTest do
  @moduledoc """
  Unit coverage for the telemetry reference module: the event list, and the
  `name_of/1` reader that puts human-readable `connection_name` /
  `subscription_name` on the outbound health events.

  The end-to-end assertions — that each event really carries the name, off records
  the pipeline already held — live in `Example.Outbound.TelemetryTest`.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Telemetry

  defmodule Named do
    @moduledoc false
    defstruct [:id, :name]
  end

  defmodule Unnamed do
    @moduledoc false
    defstruct [:id]
  end

  describe "events/0" do
    test "every emitted event is listed, so one attach_many covers the pipeline" do
      events = Telemetry.events()

      assert [:ash_integration, :delivery, :terminal] in events
      assert [:ash_integration, :delivery, :parked] in events
      assert [:ash_integration, :delivery, :delivered] in events
      assert [:ash_integration, :connection, :suspended] in events
      assert [:ash_integration, :subscription, :suspended] in events

      assert events == Enum.uniq(events)
      assert Enum.all?(events, &match?([:ash_integration, _, _], &1))
    end
  end

  describe "name_of/1" do
    test "reads the name off a loaded record" do
      assert Telemetry.name_of(%Named{id: "c1", name: "wms-eu"}) == "wms-eu"
    end

    test "an unloaded association is nil, never a load" do
      # The whole point: an emit site reads whatever it has in hand. An
      # `%Ash.NotLoaded{}` must fall through to nil rather than trigger a lookup —
      # telemetry metadata is never allowed to cost a query.
      assert Telemetry.name_of(%Ash.NotLoaded{type: :relationship}) == nil
    end

    test "a resource with no name attribute is nil, not a crash" do
      # `AshIntegration.Outbound.Delivery.Subscription` adds no `name` of its own,
      # so `subscription_name` is nil unless the host declares one.
      assert Telemetry.name_of(%Unnamed{id: "s1"}) == nil
    end

    test "a nil association, a nil name, and a non-record are all nil" do
      assert Telemetry.name_of(nil) == nil
      assert Telemetry.name_of(%Named{id: "c1", name: nil}) == nil
      assert Telemetry.name_of(%{}) == nil
      assert Telemetry.name_of("wms-eu") == nil
    end
  end
end
