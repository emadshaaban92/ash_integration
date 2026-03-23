defmodule AshIntegration.Web.Components.BelongsToInput do
  use Phoenix.LiveComponent

  import AshIntegration.Web.Components

  require Ash.Query

  @impl true
  def render(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns =
      assigns
      |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
      |> assign(:placeholder, assigns[:placeholder] || "")

    ~H"""
    <div phx-feedback-for={@field.name} class="fieldset mb-2">
      <label :if={@label}>
        <span class="label mb-1">{@label}</span>
      </label>
      <LiveSelect.live_select
        field={@field}
        style={:daisyui}
        container_extra_class="w-full"
        update_min_len={0}
        allow_clear={true}
        options={@default_options}
        placeholder={@placeholder}
        phx-target={@myself}
        phx-focus="set-default"
      />
      <.input_error :for={msg <- @errors}>{msg}</.input_error>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> set_default_options()
     |> set_field()}
  end

  @impl true
  def handle_event("live_select_change", %{"text" => search, "id" => live_select_id}, socket) do
    send_update(LiveSelect.Component,
      id: live_select_id,
      options: get_options(socket, search)
    )

    {:noreply, socket}
  end

  def handle_event("set-default", %{"id" => live_select_id}, socket) do
    send_update(LiveSelect.Component,
      id: live_select_id,
      options: get_options(socket)
    )

    {:noreply, socket}
  end

  defp set_default_options(socket) do
    assign(socket, default_options: get_options(socket))
  end

  defp set_field(socket) do
    %{form: form, relationship: relationship} = socket.assigns
    assign(socket, field: form[relationship.source_attribute])
  end

  defp get_options(socket, search \\ nil) do
    %{form: form, relationship: relationship} = socket.assigns

    result_list =
      relationship.destination
      |> default_read_query(search, socket.assigns[:actor])
      |> maybe_filter_active()
      |> maybe_load_display_name()
      |> Ash.Query.limit(50)
      |> Ash.read!()

    current =
      case Ash.Resource.loaded?(form.data, relationship.name) do
        true ->
          form.data
          |> Map.fetch!(relationship.name)
          |> List.wrap()
          |> Enum.reject(&is_nil/1)
          |> maybe_reload_display_fields(relationship.destination, socket.assigns[:actor])

        false ->
          []
      end

    (current ++ result_list)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&{display_option(&1), &1.id})
  end

  defp default_read_query(resource, search, actor) do
    action = Ash.Resource.Info.primary_action!(resource, :read)

    has_search_arg? = Enum.any?(action.arguments, &(&1.name == :search))

    query =
      if search && has_search_arg? do
        Ash.Query.for_read(resource, action.name, %{search: search}, actor: actor)
      else
        resource
        |> Ash.Query.for_read(action.name, %{}, actor: actor)
        |> maybe_filter_by_search(search)
      end

    query
  end

  defp maybe_filter_by_search(query, nil), do: query
  defp maybe_filter_by_search(query, ""), do: query

  defp maybe_filter_by_search(query, search) do
    resource = query.resource

    cond do
      Ash.Resource.Info.field(resource, :display_name) != nil ->
        Ash.Query.filter(query, contains(display_name, ^search))

      Ash.Resource.Info.attribute(resource, :name) != nil ->
        Ash.Query.filter(query, contains(name, ^search))

      true ->
        query
    end
  end

  defp maybe_filter_active(%{resource: resource} = query) do
    case Ash.Resource.Info.attribute(resource, :active) do
      nil -> query
      _ -> Ash.Query.filter(query, active)
    end
  end

  defp maybe_load_display_name(%{resource: resource} = query) do
    case Ash.Resource.Info.field(resource, :display_name) do
      nil -> maybe_load_name(query)
      _ -> query |> Ash.Query.select(:id) |> Ash.Query.load(:display_name, strict?: true)
    end
  end

  defp maybe_load_name(%{resource: resource} = query) do
    case Ash.Resource.Info.attribute(resource, :name) do
      nil -> query
      _ -> Ash.Query.select(query, :name)
    end
  end

  defp maybe_reload_display_fields([], _resource, _actor), do: []

  defp maybe_reload_display_fields(records, resource, actor) do
    ids = Enum.map(records, & &1.id)

    query =
      resource
      |> Ash.Query.filter(id in ^ids)
      |> maybe_load_display_name()

    Ash.read!(query, actor: actor)
  end

  defp display_option(%{display_name: dn}) when is_binary(dn), do: dn
  defp display_option(%{name: name}) when is_binary(name), do: name
  defp display_option(%{id: id}), do: to_string(id)

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
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
end
