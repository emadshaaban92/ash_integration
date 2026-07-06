defmodule AshIntegration.Transport.HttpWireTest do
  @moduledoc """
  Unit tests for the shared HTTP-transport machinery. Focused on
  `egress_error/2`, which both the HTTP and WhatsApp transports call with the
  category `Egress.pin/1` returns — the seam where a transient DNS failure
  (`:unresolvable`) must stay retryable while an egress-policy rejection
  (`:blocked`) / bad URL (`:invalid`) stays terminal.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntegration.Transport.HttpWire
  alias AshIntegration.Transport.Utils

  describe "strip_pinned_req_options/1 → operator cannot override the SSRF pin" do
    test "drops redirect/retry overrides (with a warning) but keeps other options" do
      log =
        capture_log(fn ->
          assert Utils.strip_pinned_req_options(
                   redirect: true,
                   retry: true,
                   connect_options: [timeout: 1_000]
                 ) == [connect_options: [timeout: 1_000]]
        end)

      assert log =~ "redirect/retry are pinned"
    end

    test "leaves req_options that touch neither pinned option untouched (no warning)" do
      log =
        capture_log(fn ->
          assert Utils.strip_pinned_req_options(connect_options: [timeout: 1_000]) ==
                   [connect_options: [timeout: 1_000]]
        end)

      refute log =~ "pinned"
    end
  end

  describe "egress_error/2 → category-aware classification" do
    test "an :unresolvable host is a RETRYABLE transport error (transient DNS)" do
      # With egress blocking OFF the same failure surfaces as an ordinary Req
      # transport error (retryable). Turning blocking ON must not make a DNS blip
      # permanently fail the delivery, so `:unresolvable` stays retryable.
      assert {:error, %{failure_class: :transport, retryable: true, error_message: msg}} =
               HttpWire.egress_error(
                 :unresolvable,
                 "egress blocked: cannot resolve host (nxdomain)"
               )

      assert msg =~ "cannot resolve"
    end

    test "a :blocked target is a NON-retryable transport error (egress policy)" do
      assert {:error, %{failure_class: :transport, retryable: false}} =
               HttpWire.egress_error(:blocked, "egress blocked: resolves to non-public address")
    end

    test "an :invalid URL is a NON-retryable transport error" do
      assert {:error, %{failure_class: :transport, retryable: false}} =
               HttpWire.egress_error(:invalid, "egress blocked: could not parse host from URL")
    end
  end
end
