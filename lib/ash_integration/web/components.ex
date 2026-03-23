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
          :if={@page.offset + @page.limit < (@page.count || 0)}
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

  attr :rest, :global,
    include:
      ~w(accept autocomplete capture cols disabled form list max maxlength min minlength multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

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
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && "select-error"]}
          multiple={@multiple}
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
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[@class || "w-full textarea", @errors != [] && "textarea-error"]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.input_error :for={msg <- @errors}>{msg}</.input_error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[@class || "w-full input", @errors != [] && "input-error"]}
          {@rest}
        />
      </label>
      <.input_error :for={msg <- @errors}>{msg}</.input_error>
    </div>
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
    do: AshIntegration.Web.OutboundIntegrationLive.Helpers.humanize(value)
end
