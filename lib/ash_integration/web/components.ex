defmodule AshIntegration.Web.Components do
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :navigate, :string, required: true
  attr :label, :string, default: "Back"

  def back_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="btn btn-ghost btn-sm gap-1">
      <.icon name="hero-arrow-left-mini" />
      {@label}
    </.link>
    """
  end

  attr :active, :atom,
    required: true,
    doc:
      "which section is current: :dashboard | :subscriptions | :event_types | :connections | :events | :deliveries | :logs"

  @nav_items [
    {:dashboard, "Dashboard", ""},
    {:subscriptions, "Subscriptions", "/subscriptions"},
    {:event_types, "Event Types", "/event-types"},
    {:connections, "Connections", "/connections"},
    {:events, "Events", "/events"},
    {:deliveries, "Deliveries", "/deliveries"},
    {:logs, "Logs", "/logs"}
  ]

  @doc """
  The outbound section sub-nav, rendered at the top of every integration page.

  The hierarchy it exposes mirrors the data model:
  *Subscriptions* + *Connections* are config; *Event Types* is the derived contract;
  *Events* (the immutable fact / outbox) → *Deliveries* (per-subscription state
  machine) → *Logs* (per-attempt) are the runtime/ops drill-down.
  """
  def outbound_nav(assigns) do
    assigns = assign(assigns, base: AshIntegration.Web.base_path(), items: @nav_items)

    ~H"""
    <nav role="tablist" class="tabs tabs-border mb-4 overflow-x-auto flex-nowrap">
      <.link
        :for={{key, label, suffix} <- @items}
        role="tab"
        navigate={@base <> suffix}
        class={["tab whitespace-nowrap", @active == key && "tab-active"]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      case @status do
        :success -> "badge-success"
        :failed -> "badge-error"
        :skipped -> "badge-warning"
        :suppressed -> "badge-neutral"
        _ -> "badge-ghost"
      end
    ]}>
      {humanize(@status)}
    </span>
    """
  end

  attr :active, :boolean, required: true

  def active_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      if(@active, do: "badge-success", else: "badge-error")
    ]}>
      {if @active, do: "Active", else: "Inactive"}
    </span>
    """
  end

  attr :value, :string, required: true

  def resource_badge(assigns) do
    ~H"""
    <span class="badge badge-sm badge-info whitespace-nowrap">
      {humanize(@value)}
    </span>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, default: "hero-inbox"
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-12">
      <.icon name={@icon} class="mx-auto h-12 w-12 text-base-content/30" />
      <h3 class="mt-2 text-sm font-semibold text-base-content/70">{@title}</h3>
      <div :if={@actions != []} class="mt-6">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  attr :page, :any, required: true
  attr :target, :any, default: nil

  def pagination(assigns) do
    ~H"""
    <div :if={@page.count && @page.count > 0} class="flex items-center justify-between py-3">
      <div class="text-sm text-base-content/60">
        Showing {@page.offset + 1} to {min(@page.offset + @page.limit, @page.count)} of {@page.count}
      </div>
      <div class="join">
        <button
          :if={@page.offset > 0}
          class="join-item btn btn-sm"
          phx-click="paginate"
          phx-value-offset={max(@page.offset - @page.limit, 0)}
          phx-target={@target}
        >
          Previous
        </button>
        <button
          :if={@page.offset + @page.limit < @page.count}
          class="join-item btn btn-sm"
          phx-click="paginate"
          phx-value-offset={@page.offset + @page.limit}
          phx-target={@target}
        >
          Next
        </button>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  @doc "A labelled value cell, shared by the outbound detail (show) pages."
  def field(assigns) do
    ~H"""
    <div>
      <div class="text-base-content/50">{@label}</div>
      <div class={["font-medium break-all", @mono && "font-mono text-xs"]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :data, :any, required: true

  @doc "Pretty-printed JSON panel; hidden when the data is nil/empty."
  def json_block(assigns) do
    ~H"""
    <div :if={@data not in [nil, %{}]} class="mb-4">
      <div class="text-sm font-medium mb-1">{@title}</div>
      <pre class="bg-base-200 rounded-box p-3 text-xs overflow-x-auto"><code>{Jason.encode!(@data, pretty: true)}</code></pre>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :text, :any, required: true

  @doc "Monospace text panel; hidden when the text is nil/empty."
  def text_block(assigns) do
    ~H"""
    <div :if={@text not in [nil, ""]} class="mb-4">
      <div class="text-sm font-medium mb-1">{@title}</div>
      <pre class="bg-base-200 rounded-box p-3 text-xs overflow-x-auto"><code>{@text}</code></pre>
    </div>
    """
  end

  attr :errors, :list, required: true, doc: "flat error strings; renders nothing when empty"

  @doc """
  A form-level "couldn't save" summary, so a failed submit never bounces back
  silently. Renders nothing when there are no errors — the caller keeps this mounted
  after a failed submit (`submitted?`), so once the operator fixes every field it
  must disappear rather than linger with a stale "review the fields" message.
  """
  def form_error_summary(assigns) do
    ~H"""
    <div :if={@errors != []} class="alert alert-error" role="alert">
      <.icon name="hero-exclamation-triangle" />
      <div>
        <p class="font-medium">This couldn't be saved.</p>
        <ul class="text-sm list-disc list-inside mt-1">
          <li :for={msg <- @errors}>{msg}</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :warnings, :list, required: true

  @doc "Non-blocking warnings for header/broker rows that would be dropped on save."
  def header_warning_banner(assigns) do
    ~H"""
    <div :if={@warnings != []} class="alert alert-warning" role="status">
      <.icon name="hero-exclamation-triangle" />
      <ul class="text-sm list-disc list-inside">
        <li :for={msg <- @warnings}>{msg}</li>
      </ul>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :prompt, :string, required: true
  attr :options, :list, required: true, doc: "[{value, label}] pairs"
  attr :selected, :any, default: nil

  @doc "A labelled filter `<select>` shared by the outbound index (all) pages."
  def filter_select(assigns) do
    ~H"""
    <label class="form-control">
      <span class="label-text text-xs mb-1">{@label}</span>
      <select name={@name} class="select select-sm select-bordered">
        <option value="">{@prompt}</option>
        <option
          :for={{value, label} <- @options}
          value={value}
          selected={to_string(value) == to_string(@selected)}
        >
          {label}
        </option>
      </select>
    </label>
    """
  end

  attr :navigate, :string, required: true

  @doc "Removable badge shown when an index page is scoped to a single subscription."
  def subscription_filter_badge(assigns) do
    ~H"""
    <.link navigate={@navigate} class="badge badge-info gap-1">
      Subscription filter <.icon name="hero-x-mark-mini" class="size-3" />
    </.link>
    """
  end

  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :errors, :list, default: []
  attr :prompt, :string, default: nil
  attr :options, :list, doc: "the options for select inputs"
  attr :multiple, :boolean, default: false
  attr :class, :any, default: nil
  attr :required, :boolean, default: false

  attr :force_errors, :boolean, default: false

  attr :rest, :global,
    include:
      ~w(accept autocomplete capture cols disabled form list max maxlength min minlength multiple pattern placeholder readonly rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors =
      if assigns.force_errors or Phoenix.Component.used_input?(field),
        do: field.errors,
        else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}<.req_mark required={@required} /></span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && "select-error"]}
          multiple={@multiple}
          required={@required}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.input_error :for={msg <- @errors}>{msg}</.input_error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}<.req_mark required={@required} /></span>
        <textarea
          id={@id}
          name={@name}
          class={[@class || "w-full textarea", @errors != [] && "textarea-error"]}
          required={@required}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.input_error :for={msg <- @errors}>{msg}</.input_error>
    </div>
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label class="flex items-center gap-2 cursor-pointer">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          name={@name}
          id={@id}
          value="true"
          checked={@checked}
          class={[@class || "toggle", @errors != [] && "toggle-error"]}
          {@rest}
        />
        <span :if={@label} class="label">{@label}<.req_mark required={@required} /></span>
      </label>
      <.input_error :for={msg <- @errors}>{msg}</.input_error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}<.req_mark required={@required} /></span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[@class || "w-full input", @errors != [] && "input-error"]}
          required={@required}
          {@rest}
        />
      </label>
      <.input_error :for={msg <- @errors}>{msg}</.input_error>
    </div>
    """
  end

  attr :required, :boolean, required: true

  # A subtle asterisk marking a required field, shown in the label.
  defp req_mark(assigns) do
    ~H"""
    <span :if={@required} class="text-error ml-0.5" aria-hidden="true" title="Required">*</span>
    """
  end

  attr :has_secret, :boolean,
    default: false,
    doc: "true when a value is already stored (edit of an existing secret)"

  attr :optional, :boolean,
    default: false,
    doc: "true when the field may be left blank even when creating"

  @doc """
  Persistent helper text under an encrypted secret input.

  The "leave blank to keep current" affordance is otherwise a placeholder only —
  invisible once the field has focus or content — so state it in the open, and
  always note that the value is stored encrypted.
  """
  def secret_hint(assigns) do
    ~H"""
    <p class="text-xs text-base-content/60 -mt-1 mb-2">
      <span :if={@optional}>Optional — leave blank if the server needs no authentication. </span>Stored encrypted.<span :if={
        @has_secret
      }> Leave blank to keep the current value.</span>
    </p>
    """
  end

  slot :inner_block, required: true

  defp input_error(assigns) do
    ~H"""
    <p class="mt-1 flex gap-1.5 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle-mini" class="size-4" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["modal", @show && "modal-open"]}
      data-cancel={@on_cancel}
    >
      <div class="modal-box w-11/12 max-w-5xl">
        <button
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
          phx-click={JS.exec("data-cancel", to: "##{@id}")}
        >
          ✕
        </button>
        {render_slot(@inner_block)}
      </div>
      <div class="modal-backdrop">
        <button phx-click={JS.exec("data-cancel", to: "##{@id}")}>close</button>
      </div>
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp humanize(value),
    do: AshIntegration.Web.Outbound.Helpers.humanize(value)
end
