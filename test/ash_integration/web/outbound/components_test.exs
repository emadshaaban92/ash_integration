defmodule AshIntegration.Web.ComponentsTest do
  @moduledoc """
  Render tests for the shared dashboard components — the filter dropdown, the badges,
  and the form-feedback pieces (error summary, header-loss warning, required marker)
  that keep a failed save from bouncing back silently.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshIntegration.Web.Components

  describe "filter_select/1" do
    test "renders the prompt and every option, marking the selected one" do
      html =
        render_component(&Components.filter_select/1,
          name: "state",
          label: "State",
          prompt: "All states",
          options: [{"pending", "Pending"}, {"failed", "Failed"}],
          selected: "failed"
        )

      assert html =~ "All states"
      assert html =~ "Pending"
      assert html =~ "Failed"
      assert html =~ ~r/value="failed"[^>]*\bselected\b/
      refute html =~ ~r/value="pending"[^>]*\bselected\b/
    end

    test "marks nothing selected when the filter is unset" do
      html =
        render_component(&Components.filter_select/1,
          name: "state",
          label: "State",
          prompt: "All",
          options: [{"pending", "Pending"}],
          selected: nil
        )

      refute html =~ ~r/value="pending"[^>]*\bselected\b/
    end
  end

  describe "status_badge/1" do
    test "maps each log status to its label and colour" do
      assert render_component(&Components.status_badge/1, status: :success) =~ "badge-success"
      assert render_component(&Components.status_badge/1, status: :failed) =~ "badge-error"
      assert render_component(&Components.status_badge/1, status: :skipped) =~ "badge-warning"
      assert render_component(&Components.status_badge/1, status: :suppressed) =~ "badge-neutral"
    end
  end

  describe "active_badge/1" do
    test "renders Active / Inactive" do
      assert render_component(&Components.active_badge/1, active: true) =~ "Active"
      assert render_component(&Components.active_badge/1, active: false) =~ "Inactive"
    end
  end

  describe "form_error_summary/1" do
    test "lists the errors it is given" do
      html =
        render_component(&Components.form_error_summary/1,
          errors: ["Name: is required", "Base url: is invalid"]
        )

      assert html =~ "alert-error"
      assert html =~ "Name: is required"
      assert html =~ "Base url: is invalid"
    end

    test "falls back to a generic message when there are no field errors" do
      html = render_component(&Components.form_error_summary/1, errors: [])
      assert html =~ "alert-error"
      assert html =~ "review the highlighted fields"
    end
  end

  describe "header_warning_banner/1" do
    test "is invisible when there are no warnings" do
      html = render_component(&Components.header_warning_banner/1, warnings: [])
      refute html =~ "alert-warning"
    end

    test "lists each warning" do
      html =
        render_component(&Components.header_warning_banner/1,
          warnings: ["A header row has a value but no name — it will be dropped on save."]
        )

      assert html =~ "alert-warning"
      assert html =~ "dropped on save"
    end
  end

  describe "input/1 required marker" do
    test "shows a required marker and native attribute when required" do
      html =
        render_component(&Components.input/1,
          name: "name",
          label: "Name",
          type: "text",
          value: "",
          required: true
        )

      assert html =~ "Name"
      assert html =~ "text-error"
      assert html =~ "required"
    end

    test "shows no marker when the field is optional" do
      html =
        render_component(&Components.input/1,
          name: "name",
          label: "Name",
          type: "text",
          value: ""
        )

      refute html =~ "text-error"
    end
  end
end
