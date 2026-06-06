defmodule AshIntegration.Web.Outbound.SubscriptionLive.FormComponent do
  @moduledoc false
  use AshIntegration.Web, :live_component

  alias AshIntegration.Web.Outbound.SubscriptionLive.Helpers

  @impl true
  def update(assigns, socket) do
    socket =
      assign(
        socket,
        Map.take(assigns, [
          :id,
          :actor,
          :action,
          :connection,
          :subscription,
          :navigate,
          :connections
        ])
      )

    socket = assign_new(socket, :connections, fn -> [] end)
    socket = if socket.assigns[:form], do: socket, else: init_form(socket)
    {:ok, socket}
  end

  defp init_form(%{assigns: %{action: :new_subscription, actor: actor} = assigns} = socket) do
    {default_type, default_version} = default_selection()

    default_conn_id =
      case assigns do
        %{connection: %{id: id}} -> id
        %{connections: [%{id: id} | _]} -> id
        _ -> nil
      end

    form =
      AshPhoenix.Form.for_create(AshIntegration.subscription_resource(), :create,
        actor: actor,
        params: %{
          "connection_id" => default_conn_id,
          "event_type" => default_type,
          "version" => default_version
          # transform_source intentionally omitted — it's optional and defaults to
          # nil (a no-op that sends the resolved delivery defaults).
        }
      )

    socket
    |> assign(
      form: form,
      submitted?: false,
      selected_transport: transport_for(assigns, default_conn_id),
      route: %{}
    )
    |> Helpers.assign_form_options(form)
  end

  defp init_form(
         %{
           assigns:
             %{action: :edit_subscription, subscription: subscription, actor: actor} = assigns
         } =
           socket
       ) do
    form = AshPhoenix.Form.for_update(subscription, :update, actor: actor)

    socket
    |> assign(
      form: form,
      submitted?: false,
      selected_transport: transport_for(assigns, subscription.connection_id),
      route: route_to_strings(subscription.route_config)
    )
    |> Helpers.assign_form_options(form)
  end

  defp default_selection do
    case Helpers.event_type_options() do
      [{_, type} | _] ->
        version =
          case Helpers.version_options(type) do
            [{_, v} | _] -> v
            _ -> nil
          end

        {type, version}

      _ ->
        {nil, nil}
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    new_transport = transport_for(socket.assigns, params["connection_id"])
    # Switching to a connection with a different transport invalidates the route —
    # reset it rather than try to cast e.g. an HTTP route onto a Kafka connection.
    transport_changed? = new_transport != socket.assigns.selected_transport
    transport = new_transport || socket.assigns.selected_transport

    route =
      if transport_changed?,
        do: %{},
        else: Map.merge(socket.assigns.route, params["route"] || %{})

    form =
      AshPhoenix.Form.validate(socket.assigns.form, with_route_config(params, transport, route))

    {:noreply,
     socket
     |> assign(form: form, selected_transport: transport, route: route)
     |> Helpers.assign_form_options(form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    route = Map.merge(socket.assigns.route, params["route"] || %{})

    params = with_route_config(params, socket.assigns.selected_transport, route)

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, record} ->
        notify_parent({:saved, record})

        {:noreply,
         socket
         |> put_flash(:info, success_message(socket.assigns.action))
         |> push_navigate(to: socket.assigns.navigate)}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(form: form, submitted?: true, route: route)
         |> Helpers.assign_form_options(form)}
    end
  end

  # ── Route ⇆ route_config union plumbing ─────────────────────────────────────

  # The route fields are plain inputs (the route's transport variant is fixed by
  # the connection, not chosen by the user), assembled here into the
  # `route_config` union params AshPhoenix/Ash expects.
  defp with_route_config(params, transport, route) do
    params = Map.delete(params, "route")

    case route_config_params(transport, route) do
      nil -> params
      rc -> Map.put(params, "route_config", rc)
    end
  end

  defp route_config_params("http", route) do
    %{"_union_type" => "http"}
    |> maybe_put("path", route["path"])
    |> maybe_put("method", route["method"])
    |> maybe_put("timeout_ms", route["timeout_ms"])
  end

  defp route_config_params("kafka", route) do
    maybe_put(%{"_union_type" => "kafka"}, "topic", route["topic"])
  end

  defp route_config_params(_transport, _route), do: nil

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp route_to_strings(%Ash.Union{type: :http, value: route}) do
    %{
      "path" => route.path,
      "method" => route.method && to_string(route.method),
      "timeout_ms" => route.timeout_ms && to_string(route.timeout_ms)
    }
  end

  defp route_to_strings(%Ash.Union{type: :kafka, value: route}), do: %{"topic" => route.topic}
  defp route_to_strings(_), do: %{}

  # The transport type of the currently-selected connection, so the form shows the
  # right per-route fields (HTTP path/method vs Kafka topic).
  defp transport_for(assigns, conn_id) do
    conn_id = to_string(conn_id)

    connections =
      case assigns[:connection] do
        %{} = connection -> [connection]
        _ -> assigns[:connections] || []
      end

    case Enum.find(connections, &(to_string(&1.id) == conn_id)) do
      %{transport_config: %Ash.Union{type: type}} -> to_string(type)
      _ -> nil
    end
  end

  defp success_message(:new_subscription), do: "Subscription created"
  defp success_message(:edit_subscription), do: "Subscription updated"

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        :let={f}
        for={@form}
        id={@id}
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <div class="space-y-4">
          <.input :if={@connections == []} field={f[:connection_id]} type="hidden" />
          <.input
            :if={@connections != []}
            field={f[:connection_id]}
            type="select"
            label="Connection"
            options={Enum.map(@connections, &{&1.name, &1.id})}
            required
          />
          <.input
            field={f[:event_type]}
            type="select"
            label="Event Type"
            options={@event_type_options}
            required
          />
          <p class="text-xs text-base-content/50 -mt-2">
            From the derived event catalog. The event key (ordering + coalescing) is resolved by
            the producer, not chosen here.
          </p>
          <.input
            field={f[:version]}
            type="select"
            label="Version"
            options={@version_options}
            required
          />

          <div class="card card-border border-base-300 p-4">
            <h4 class="font-semibold mb-1">Delivery route</h4>
            <p class="text-xs text-base-content/50 mb-3">
              Where this event type is delivered, on top of the connection's host/auth.
            </p>
            <%= case @selected_transport do %>
              <% "http" -> %>
                <label class="label">HTTP Method</label>
                <select name="form[route][method]" class="select select-bordered w-full">
                  <option
                    :for={m <- ~w(post put patch delete)}
                    value={m}
                    selected={selected_method?(@route["method"], m)}
                  >
                    {String.upcase(m)}
                  </option>
                </select>
                <label class="label mt-2">Path</label>
                <input
                  type="text"
                  name="form[route][path]"
                  value={@route["path"]}
                  placeholder="/widgets"
                  class="input input-bordered w-full"
                  phx-debounce="blur"
                />
                <label class="label mt-2">Timeout override (ms)</label>
                <input
                  type="text"
                  name="form[route][timeout_ms]"
                  value={@route["timeout_ms"]}
                  placeholder="Leave blank to use the connection default"
                  class="input input-bordered w-full"
                  phx-debounce="blur"
                />
                <p class="text-xs text-base-content/50 mt-1">
                  The path is joined onto the connection's base URL. Leave it blank to deliver to the
                  base URL itself (single-endpoint webhooks); method defaults to POST.
                </p>
              <% "kafka" -> %>
                <label class="label">Topic override</label>
                <input
                  type="text"
                  name="form[route][topic]"
                  value={@route["topic"]}
                  placeholder="Leave blank to use the connection's default topic"
                  class="input input-bordered w-full"
                  phx-debounce="blur"
                />
              <% _ -> %>
                <p class="text-xs text-base-content/60">
                  Pick a connection above to configure its delivery route.
                </p>
            <% end %>
          </div>

          <.input
            field={f[:transform_source]}
            type="textarea"
            label="Transform (optional)"
            placeholder={"-- Leave blank to send the defaults, or expose a transform:\nfunction transform(event, defaults)\n  defaults.body = { id = event.data.id }\n  defaults.headers[\"x-tenant\"] = event.data.tenant\n  return defaults\nend"}
            phx-debounce="500"
            rows="8"
          />
          <ul class="text-xs text-base-content/60 mt-1 list-disc list-inside space-y-0.5">
            <li>
              Expose a <strong>Lua</strong>
              function <code class="text-xs">transform(event, defaults)</code>
              to customize delivery (optional).
            </li>
            <li>
              <code class="text-xs">event</code>
              is the incoming event (a table); <code class="text-xs">defaults</code>
              is the descriptor this route would send
              (<code class="text-xs">body</code>, <code class="text-xs">headers</code>, routing).
            </li>
            <li>
              <strong>Return</strong>
              the descriptor to deliver — mutate and return <code class="text-xs">defaults</code>, or build a fresh table. Exposing
              no <code class="text-xs">transform</code>
              sends the defaults unchanged.
            </li>
            <li>
              Return <code class="text-xs">nil</code> to skip the event.
            </li>
          </ul>

          <div
            :if={@sample_event}
            id={"sample-event-#{f[:event_type].value}-#{f[:version].value}"}
            phx-update="ignore"
            class="collapse collapse-arrow bg-base-200 mt-2"
          >
            <input type="checkbox" />
            <div class="collapse-title text-sm font-medium">Sample Event</div>
            <div class="collapse-content">
              <pre class="text-xs overflow-x-auto"><code>{@sample_event}</code></pre>
            </div>
          </div>

          <div :if={@transform_preview} class="mt-2">
            <div :if={match?({:error, _}, @transform_preview)} class="alert alert-error text-xs">
              <.icon name="hero-exclamation-triangle-mini" />
              <span>{elem(@transform_preview, 1)}</span>
            </div>
            <div :if={@transform_preview == {:ok, :skip}} class="alert alert-warning text-xs">
              <.icon name="hero-forward-mini" />
              <span>Delivery will be skipped (result = nil)</span>
            </div>
            <div
              :if={match?({:ok, json} when is_binary(json), @transform_preview)}
              class="collapse collapse-arrow bg-base-200"
            >
              <input type="checkbox" checked />
              <div class="collapse-title text-sm font-medium">Transform Result</div>
              <div class="collapse-content">
                <pre class="text-xs overflow-x-auto"><code>{elem(@transform_preview, 1)}</code></pre>
              </div>
            </div>
          </div>

          <div class="card card-border border-base-300 p-4 mt-4">
            <.input
              field={f[:notify_on_every_change]}
              type="checkbox"
              label="Notify on every change"
            />
            <p class="text-xs text-base-content/50 mt-1">
              By default only the <strong>latest</strong>
              state per event key is delivered; older queued events for the same key are dropped
              (kept as <code class="text-xs">cancelled</code>
              for audit). Enable this to send <strong>one delivery per change</strong>.
            </p>
          </div>

          <div class="card card-border border-base-300 p-4 mt-4">
            <.input
              field={f[:suppress_unchanged]}
              type="checkbox"
              label="Suppress unchanged deliveries"
            />
            <p class="text-xs text-base-content/50 mt-1">
              Skip a delivery whose <strong>body</strong>
              is identical to the one last delivered for the same event key — a value
              that bounces back (e.g. stock <code class="text-xs">5 → 6 → 5</code>) still sends.
              Withheld deliveries are recorded as <code class="text-xs">suppressed</code>
              (not <code class="text-xs">delivered</code>), so "last delivered" stays an honest
              signal. Set <code class="text-xs">result.dedup_on</code>
              in the transform to compare on something other than the body (e.g. a header).
            </p>
          </div>
        </div>

        <div class="modal-action">
          <button type="button" class="btn" phx-click={JS.navigate(@navigate)}>Cancel</button>
          <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
            {if @action == :new_subscription, do: "Create", else: "Save Changes"}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp selected_method?(current, option) when current in [nil, ""], do: option == "post"
  defp selected_method?(current, option), do: current == option
end
