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

    test "uses the daisyUI 5 fieldset/label markup, not the removed v4 classes" do
      html =
        render_component(&Components.filter_select/1,
          name: "state",
          label: "State",
          prompt: "All",
          options: [{"pending", "Pending"}],
          selected: nil
        )

      # v5 pattern present…
      assert html =~ "fieldset"
      assert html =~ ~s(class="label)
      assert html =~ ~s(class="select select-sm")
      # …and the classes daisyUI 5 dropped are gone.
      refute html =~ "form-control"
      refute html =~ "label-text"
      refute html =~ "select-bordered"
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

    test "renders nothing when there are no errors (so a fixed form clears the summary)" do
      html = render_component(&Components.form_error_summary/1, errors: [])
      refute html =~ "alert-error"
    end
  end

  describe "header_warning_tip/1" do
    test "renders nothing when there are no warnings" do
      html = render_component(&Components.header_warning_tip/1, warnings: [])
      refute html =~ "dropped on save"
    end

    test "lists each warning" do
      html =
        render_component(&Components.header_warning_tip/1,
          warnings: ["A header row has a value but no name — it will be dropped on save."]
        )

      assert html =~ "dropped on save"
    end
  end

  describe "secret_hint/1" do
    test "always states the value is stored encrypted (persistent, not a placeholder)" do
      html = render_component(&Components.secret_hint/1, has_secret: false)
      assert html =~ "Stored encrypted"
      # A brand-new secret has nothing to keep, so no leave-blank affordance.
      refute html =~ "keep the current value"
      refute html =~ "Optional"
    end

    test "explains the leave-blank-to-keep behavior when a secret already exists" do
      html = render_component(&Components.secret_hint/1, has_secret: true)
      assert html =~ "Stored encrypted"
      assert html =~ "Leave blank to keep the current value"
    end

    test "marks the field optional when auth may be skipped (e.g. SMTP)" do
      html = render_component(&Components.secret_hint/1, has_secret: false, optional: true)
      assert html =~ "Optional"
      assert html =~ "no authentication"
      assert html =~ "Stored encrypted"
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
