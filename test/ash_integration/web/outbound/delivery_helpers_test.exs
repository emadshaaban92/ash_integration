defmodule AshIntegration.Web.Outbound.DeliveryLive.HelpersTest do
  @moduledoc """
  The delivery-state badge is the single source of truth an operator scans to know
  what a delivery is doing. It has to badge each state honestly — a delivered row
  must never read as an error (the failed-then-succeeded case), a non-terminal
  `:failed` row is "Retrying" not "Failed", and a terminal head is called out
  distinctly. These render tests lock that vocabulary in.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshIntegration.Web.Outbound.DeliveryLive.Helpers

  defp badge(delivery), do: render_component(&Helpers.state_badge/1, delivery: delivery)

  describe "state_badge/1" do
    test "a delivered row reads Delivered (success) and never leaks an earlier error" do
      html = badge(%{state: :delivered, terminal_reason: nil, last_error: "connection refused"})

      assert html =~ "Delivered"
      assert html =~ "badge-success"
      refute html =~ "Terminal"
      refute html =~ "connection refused"
    end

    test "a non-terminal failed row reads Retrying, not Failed" do
      html = badge(%{state: :failed, terminal_reason: nil})

      assert html =~ "Retrying"
      assert html =~ "badge-warning"
      refute html =~ "Terminal"
    end

    test "a terminal failed row reads Terminal with its reason" do
      html = badge(%{state: :failed, terminal_reason: :permanent})

      assert html =~ "Terminal"
      assert html =~ "permanent"
      assert html =~ "badge-error"
    end

    test "a parked row reads Parked" do
      html = badge(%{state: :parked, terminal_reason: nil})

      assert html =~ "Parked"
      assert html =~ "badge-error"
    end

    test "a suppressed row reads Suppressed (neutral — a deliberate no-send, not a failure)" do
      html = badge(%{state: :suppressed, terminal_reason: nil})

      assert html =~ "Suppressed"
      assert html =~ "badge-neutral"
    end
  end

  describe "parked?/1 and terminal?/1" do
    test "parked? is true only for the :parked state" do
      assert Helpers.parked?(%{state: :parked})
      refute Helpers.parked?(%{state: :failed})
      refute Helpers.parked?(%{state: :delivered})
    end

    test "terminal? is true only for a failed row carrying a terminal_reason" do
      assert Helpers.terminal?(%{state: :failed, terminal_reason: :expired})
      refute Helpers.terminal?(%{state: :failed, terminal_reason: nil})
      refute Helpers.terminal?(%{state: :delivered, terminal_reason: nil})
    end

    # A lean list projection that forgets to select a badge field must fail loud,
    # not silently mislabel the row via the catch-all clause.
    test "the badge predicates raise when a required field is unloaded" do
      assert_raise ArgumentError, ~r/state/, fn ->
        Helpers.parked?(%{state: %Ash.NotLoaded{}})
      end

      assert_raise ArgumentError, ~r/state/, fn ->
        Helpers.terminal?(%{state: %Ash.NotLoaded{}})
      end

      assert_raise ArgumentError, ~r/terminal_reason/, fn ->
        Helpers.terminal?(%{state: :failed, terminal_reason: %Ash.NotLoaded{}})
      end
    end
  end

  describe "health_badge/1" do
    test "renders nothing for a healthy record (no parked backlog)" do
      html = render_component(&Helpers.health_badge/1, record: %{parked_count: 0})
      assert String.trim(html) == ""
    end

    test "surfaces the parked count when the record is unhealthy" do
      html = render_component(&Helpers.health_badge/1, record: %{parked_count: 9999})
      assert html =~ "9999"
      assert html =~ "badge"
    end
  end
end
