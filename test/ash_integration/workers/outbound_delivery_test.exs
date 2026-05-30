defmodule AshIntegration.Workers.OutboundDeliveryTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Workers.OutboundDelivery

  describe "delivery_decision/2" do
    test "delivers when the event is scheduled and the integration is not suspended" do
      assert :deliver =
               OutboundDelivery.delivery_decision(
                 %{state: :scheduled},
                 %{suspended: false}
               )
    end

    test "halts (parks + cancels) when the integration is suspended" do
      assert :halt_suspended =
               OutboundDelivery.delivery_decision(
                 %{state: :scheduled},
                 %{suspended: true}
               )
    end

    test "no-ops when the event is no longer scheduled, regardless of suspension" do
      for state <- [:pending, :delivered, :cancelled],
          suspended <- [true, false] do
        assert :noop =
                 OutboundDelivery.delivery_decision(
                   %{state: state},
                   %{suspended: suspended}
                 )
      end
    end

    test "the not-scheduled guard takes precedence over suspension" do
      # A cancelled/delivered event on a suspended integration should not be
      # re-parked — it's already terminal.
      assert :noop =
               OutboundDelivery.delivery_decision(
                 %{state: :delivered},
                 %{suspended: true}
               )
    end
  end
end
