defmodule AshIntegration.Web.Outbound.EventLive.HelpersTest do
  @moduledoc """
  The Event (outbox) badge distinguishes the three lifecycle states an operator acts
  on differently: still in the outbox, dispatched, or stuck (undispatched + terminal).
  A stuck fact must read as an error, not a benign "in outbox".
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshIntegration.Web.Outbound.EventLive.Helpers

  defp badge(event), do: render_component(&Helpers.outbox_badge/1, event: event)

  describe "outbox_badge/1" do
    test "an undispatched fact reads In outbox (warning)" do
      html = badge(%{dispatched_at: nil, dispatch_terminal_reason: nil})
      assert html =~ "In outbox"
      assert html =~ "badge-warning"
    end

    test "a dispatched fact reads Dispatched (success)" do
      html = badge(%{dispatched_at: ~U[2026-07-12 00:00:00Z], dispatch_terminal_reason: nil})
      assert html =~ "Dispatched"
      assert html =~ "badge-success"
    end

    test "an undispatched + terminal fact reads Stuck (error) with its reason" do
      html = badge(%{dispatched_at: nil, dispatch_terminal_reason: :expired})
      assert html =~ "Stuck"
      assert html =~ "expired"
      assert html =~ "badge-error"
    end
  end

  describe "stuck?/1 and dispatched?/1" do
    test "stuck? only when undispatched and terminal" do
      assert Helpers.stuck?(%{dispatched_at: nil, dispatch_terminal_reason: :expired})
      refute Helpers.stuck?(%{dispatched_at: nil, dispatch_terminal_reason: nil})
    end

    test "dispatched? tracks the dispatched_at stamp" do
      refute Helpers.dispatched?(%{dispatched_at: nil})
      assert Helpers.dispatched?(%{dispatched_at: ~U[2026-07-12 00:00:00Z]})
    end
  end
end
