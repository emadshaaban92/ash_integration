defmodule AshIntegration.Web.OutboundIntegrationLive.FormComponent do
  use AshIntegration.Web, :live_component

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id, :actor, :action, :integration, :navigate]))

    socket =
      if socket.assigns[:form] do
        socket
      else
        init_form(socket)
      end

    {:ok, socket}
  end

  defp init_form(%{assigns: %{action: :new, actor: actor}} = socket) do
    resource = AshIntegration.outbound_integration_resource()
    defaults = Helpers.create_form_defaults()

    form =
      AshPhoenix.Form.for_create(resource, :create,
        actor: actor,
        forms: [auto?: true],
        params: defaults
      )
      |> AshPhoenix.Form.add_form("form[transport_config]", params: %{"_union_type" => "http"})
      |> Helpers.ensure_auth_subform()

    socket
    |> assign(
      form: form,
      header_rows: [],
      broker_rows: [],
      kafka_header_rows: [],
      grpc_header_rows: [],
      has_secrets: %{},
      submitted?: false,
      selected_transport: "http"
    )
    |> Helpers.assign_form_options(form)
  end

  defp init_form(%{assigns: %{action: :edit, integration: integration, actor: actor}} = socket) do
    form =
      AshPhoenix.Form.for_update(integration, :update, actor: actor, forms: [auto?: true])
      |> Helpers.ensure_auth_subform()

    selected_transport = transport_type(integration.transport_config)

    {header_rows, broker_rows, kafka_header_rows, grpc_header_rows} =
      case integration.transport_config do
        %Ash.Union{type: :http, value: config} ->
          rows =
            (config.headers || %{})
            |> Enum.map(fn {k, v} -> {System.unique_integer([:positive]), {k, v}} end)

          {rows, [], [], []}

        %Ash.Union{type: :kafka, value: config} ->
          brokers =
            (config.brokers || [])
            |> Enum.map(fn b -> {System.unique_integer([:positive]), b} end)

          kafka_headers =
            (config.headers || %{})
            |> Enum.map(fn {k, v} -> {System.unique_integer([:positive]), {k, v}} end)

          {[], brokers, kafka_headers, []}

        %Ash.Union{type: :grpc, value: config} ->
          grpc_headers =
            (config.headers || %{})
            |> Enum.map(fn {k, v} -> {System.unique_integer([:positive]), {k, v}} end)

          {[], [], [], grpc_headers}

        _ ->
          {[], [], [], []}
      end

    socket
    |> assign(
      form: form,
      header_rows: header_rows,
      broker_rows: broker_rows,
      kafka_header_rows: kafka_header_rows,
      grpc_header_rows: grpc_header_rows,
      submitted?: false,
      selected_transport: selected_transport
    )
    |> assign(has_secrets: Helpers.detect_existing_secrets(integration))
    |> Helpers.assign_form_options(form)
  end

  @impl true
  def handle_event("add-header", _, socket) do
    id = System.unique_integer([:positive])
    {:noreply, assign(socket, header_rows: socket.assigns.header_rows ++ [{id, {"", ""}}])}
  end

  def handle_event("remove-header", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.header_rows, fn {row_id, _} -> row_id == id end)
    {:noreply, assign(socket, header_rows: rows)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    params = params |> Helpers.inject_headers_map() |> Helpers.strip_blank_secrets()
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    {:noreply,
     socket
     |> assign(form: form)
     |> Helpers.assign_form_options(form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    params = params |> Helpers.inject_headers_map() |> Helpers.strip_blank_secrets()

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, record} ->
        notify_parent({:saved, record})

        {:noreply,
         socket
         |> put_flash(:info, success_message(socket.assigns.action))
         |> push_navigate(to: socket.assigns.navigate)}

      {:error, form} ->
        {:noreply, assign(socket, form: form, submitted?: true)}
    end
  end

  def handle_event("transport-type-changed", %{"transport_selector" => new_type}, socket) do
    form =
      socket.assigns.form
      |> AshPhoenix.Form.remove_form("form[transport_config]")
      |> AshPhoenix.Form.add_form("form[transport_config]",
        params: %{"_union_type" => new_type}
      )

    form =
      case new_type do
        "http" -> Helpers.ensure_auth_subform(form)
        "kafka" -> Helpers.ensure_security_subform(form)
        "grpc" -> Helpers.ensure_security_subform(form)
      end

    has_secrets = %{signing_secret: false, auth: false, sasl_password: false}

    {:noreply,
     socket
     |> assign(
       form: form,
       selected_transport: new_type,
       header_rows: [],
       broker_rows: [],
       kafka_header_rows: [],
       grpc_header_rows: [],
       has_secrets: has_secrets
     )
     |> Helpers.assign_form_options(form)}
  end

  def handle_event("add-broker", _, socket) do
    id = System.unique_integer([:positive])
    {:noreply, assign(socket, broker_rows: socket.assigns.broker_rows ++ [{id, ""}])}
  end

  def handle_event("remove-broker", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.broker_rows, fn {row_id, _} -> row_id == id end)
    {:noreply, assign(socket, broker_rows: rows)}
  end

  def handle_event("add-kafka-header", _, socket) do
    id = System.unique_integer([:positive])

    {:noreply,
     assign(socket, kafka_header_rows: socket.assigns.kafka_header_rows ++ [{id, {"", ""}}])}
  end

  def handle_event("remove-kafka-header", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.kafka_header_rows, fn {row_id, _} -> row_id == id end)
    {:noreply, assign(socket, kafka_header_rows: rows)}
  end

  def handle_event("add-grpc-header", _, socket) do
    id = System.unique_integer([:positive])

    {:noreply,
     assign(socket, grpc_header_rows: socket.assigns.grpc_header_rows ++ [{id, {"", ""}}])}
  end

  def handle_event("remove-grpc-header", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.grpc_header_rows, fn {row_id, _} -> row_id == id end)
    {:noreply, assign(socket, grpc_header_rows: rows)}
  end

  def handle_event("security-type-changed", %{"_target" => path} = params, socket) do
    new_type = get_in(params, path)
    form_path = :lists.droplast(path)

    form =
      socket.assigns.form
      |> AshPhoenix.Form.remove_form(form_path)
      |> AshPhoenix.Form.add_form(form_path, params: %{"_union_type" => new_type})

    has_secrets = Map.put(socket.assigns[:has_secrets] || %{}, :sasl_password, false)

    {:noreply,
     socket
     |> assign(form: form, has_secrets: has_secrets)
     |> Helpers.assign_form_options(form)}
  end

  def handle_event("auth-type-changed", %{"_target" => path} = params, socket) do
    new_type = get_in(params, path)
    form_path = :lists.droplast(path)

    form =
      socket.assigns.form
      |> AshPhoenix.Form.remove_form(form_path)
      |> AshPhoenix.Form.add_form(form_path, params: %{"_union_type" => new_type})

    has_secrets = Map.put(socket.assigns[:has_secrets] || %{}, :auth, false)

    {:noreply,
     socket
     |> assign(form: form, has_secrets: has_secrets)
     |> Helpers.assign_form_options(form)}
  end

  defp transport_type(%Ash.Union{type: type}), do: to_string(type)
  defp transport_type(_), do: "http"

  defp success_message(:new), do: "Integration created"
  defp success_message(:edit), do: "Integration updated"

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
        <.form_fields
          form={f}
          action={@action}
          has_secrets={@has_secrets}
          submitted?={@submitted?}
          resource_options={@resource_options}
          action_options={@action_options}
          schema_version_options={@schema_version_options}
          sample_event={@sample_event}
          transform_preview={@transform_preview}
          actor={@actor}
          header_rows={@header_rows}
          broker_rows={@broker_rows}
          kafka_header_rows={@kafka_header_rows}
          grpc_header_rows={@grpc_header_rows}
          selected_transport={@selected_transport}
          myself={@myself}
        />
        <div class="modal-action">
          <button
            type="button"
            class="btn"
            phx-click={JS.navigate(@navigate)}
          >
            Cancel
          </button>
          <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
            {if @action == :new, do: "Create", else: "Save Changes"}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :action, :atom, required: true
  attr :has_secrets, :map, default: %{}
  attr :submitted?, :boolean, default: false
  attr :resource_options, :list, required: true
  attr :action_options, :list, required: true
  attr :schema_version_options, :list, required: true
  attr :sample_event, :string, default: nil
  attr :transform_preview, :any, default: nil
  attr :actor, :any, default: nil
  attr :header_rows, :list, default: []
  attr :broker_rows, :list, default: []
  attr :kafka_header_rows, :list, default: []
  attr :grpc_header_rows, :list, default: []
  attr :selected_transport, :string, default: "http"
  attr :myself, :any, required: true

  defp form_fields(assigns) do
    ~H"""
    <div class="space-y-4">
      <.input field={@form[:name]} type="text" label="Name" required phx-debounce="blur" />
      <.input
        field={@form[:resource]}
        type="select"
        label="Resource"
        options={@resource_options}
        required
      />
      <.input
        field={@form[:actions]}
        type="select"
        label="Actions"
        options={@action_options}
        multiple
        required
        size="4"
      />
      <.input
        field={@form[:schema_version]}
        type="select"
        label="Schema Version"
        options={@schema_version_options}
        required
      />
      <.live_component
        id="select-owner_id"
        module={AshIntegration.Web.Components.BelongsToInput}
        label="Owner"
        relationship={
          Ash.Resource.Info.relationship(AshIntegration.outbound_integration_resource(), :owner)
        }
        form={@form}
        actor={@actor}
      />
      <.input
        field={@form[:transform_script]}
        type="textarea"
        label="Transform Script"
        required
        phx-debounce="500"
        rows="6"
      />
      <ul class="text-xs text-base-content/60 mt-1 list-disc list-inside space-y-0.5">
        <li>Write a <strong>Lua</strong> script to transform the event before delivery.</li>
        <li>The incoming event is available as <code class="text-xs">event</code> (a table).</li>
        <li>Set <code class="text-xs">result</code> to the transformed payload to send.</li>
        <li>If <code class="text-xs">result</code> is not set, the delivery is skipped.</li>
      </ul>
      <div
        :if={@sample_event}
        id={"sample-event-#{@form[:resource].value}-#{@form[:schema_version].value}"}
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
          <span>Delivery will be skipped (result not set)</span>
        </div>
        <%= if match?({:ok, _, _, _}, @transform_preview) do %>
          <% {_, json, errors, warnings} = @transform_preview %>
          <div class="collapse collapse-arrow bg-base-200">
            <input type="checkbox" checked />
            <div class="collapse-title text-sm font-medium">Transform Result</div>
            <div class="collapse-content">
              <pre class="text-xs overflow-x-auto"><code>{json}</code></pre>
            </div>
          </div>
          <div :if={errors != []} class="alert alert-error text-xs mt-2">
            <div>
              <div class="font-semibold mb-1">Proto validation errors (delivery will fail):</div>
              <ul class="list-disc list-inside space-y-0.5">
                <li :for={error <- errors}>{error}</li>
              </ul>
            </div>
          </div>
          <div :if={warnings != []} class="alert alert-warning text-xs mt-2">
            <div>
              <div class="font-semibold mb-1">Proto validation warnings:</div>
              <ul class="list-disc list-inside space-y-0.5">
                <li :for={warning <- warnings}>{warning}</li>
              </ul>
            </div>
          </div>
        <% else %>
          <div
            :if={match?({:ok, _}, @transform_preview) and @transform_preview != {:ok, :skip}}
            class="collapse collapse-arrow bg-base-200"
          >
            <input type="checkbox" checked />
            <div class="collapse-title text-sm font-medium">Transform Result</div>
            <div class="collapse-content">
              <pre class="text-xs overflow-x-auto"><code>{elem(@transform_preview, 1)}</code></pre>
            </div>
          </div>
        <% end %>
      </div>

      <div class="mt-4">
        <.input
          type="select"
          label="Transport"
          name="transport_selector"
          value={@selected_transport}
          options={transport_options(@selected_transport)}
          phx-change="transport-type-changed"
          phx-target={@myself}
        />
      </div>

      <.inputs_for :let={tc} field={@form[:transport_config]}>
        <div class="card card-border border-base-300 p-4 mt-4">
          <%= cond do %>
            <% @selected_transport == "http" -> %>
              <h4 class="font-semibold mb-3">HTTP Configuration</h4>
              <.input
                field={tc[:method]}
                type="select"
                label="HTTP Method"
                options={[
                  {"POST", "post"},
                  {"PUT", "put"},
                  {"PATCH", "patch"},
                  {"DELETE", "delete"}
                ]}
              />
              <.input
                field={tc[:url]}
                type="text"
                label="URL"
                placeholder="https://example.com/webhook"
                required
                phx-debounce="blur"
              />
              <.input
                field={tc[:timeout_ms]}
                type="text"
                label="Timeout (ms)"
                required
                phx-debounce="blur"
              />
              <label class="label">Custom Headers</label>
              <div class="space-y-2">
                <div :for={{id, {key, value}} <- @header_rows} class="flex gap-2 items-center">
                  <input
                    type="text"
                    name={tc[:headers].name <> "[#{id}][key]"}
                    value={key}
                    placeholder="Header name"
                    class="input input-bordered input-sm flex-1"
                    phx-debounce="blur"
                  />
                  <input
                    type="text"
                    name={tc[:headers].name <> "[#{id}][value]"}
                    value={value}
                    placeholder="Header value"
                    class="input input-bordered input-sm flex-1"
                    phx-debounce="blur"
                  />
                  <button
                    type="button"
                    phx-click="remove-header"
                    phx-target={@myself}
                    phx-value-id={id}
                    class="btn btn-ghost btn-sm btn-square"
                  >
                    &times;
                  </button>
                </div>
                <button
                  type="button"
                  phx-click="add-header"
                  phx-target={@myself}
                  class="btn btn-outline btn-xs"
                >
                  + Add Header
                </button>
              </div>

              <div class="divider my-2"></div>
              <h5 class="font-semibold mb-3">Payload Signing</h5>
              <.input
                field={tc[:signing_secret]}
                type="password"
                autocomplete="one-time-code"
                label="HMAC Signing Secret"
                placeholder={
                  if @has_secrets[:signing_secret],
                    do: "Leave blank to keep current",
                    else: "Leave blank to disable signing"
                }
                phx-debounce="blur"
              />
              <p class="text-xs text-base-content/50 mt-1">
                When set, payloads are signed with HMAC-SHA256. The signature is sent in the
                <code class="text-xs">x-payload-signature</code>
                header as <code class="text-xs">t=timestamp,v1=hex_digest</code>.
              </p>

              <div class="divider my-2"></div>
              <h5 class="font-semibold mb-3">Authentication</h5>

              <.inputs_for :let={auth} field={tc[:auth]}>
                <.input
                  field={auth[:_union_type]}
                  phx-change="auth-type-changed"
                  phx-target={@myself}
                  type="select"
                  label="Auth Method"
                  options={[
                    {"No Auth", "none"},
                    {"Bearer Token", "bearer_token"},
                    {"API Key", "api_key"},
                    {"Basic Auth", "basic_auth"}
                  ]}
                />
                <%= case auth.params["_union_type"] do %>
                  <% "bearer_token" -> %>
                    <.input
                      field={auth[:token]}
                      type="password"
                      autocomplete="one-time-code"
                      label="Token"
                      required={@action == :new}
                      force_errors={@submitted?}
                      placeholder={if @has_secrets[:auth], do: "Leave blank to keep current"}
                      phx-debounce="blur"
                    />
                  <% "api_key" -> %>
                    <.input
                      field={auth[:header_name]}
                      type="text"
                      label="Header Name"
                      required
                      force_errors={@submitted?}
                      phx-debounce="blur"
                    />
                    <.input
                      field={auth[:value]}
                      type="password"
                      autocomplete="one-time-code"
                      label="API Key Value"
                      required={@action == :new}
                      force_errors={@submitted?}
                      placeholder={if @has_secrets[:auth], do: "Leave blank to keep current"}
                      phx-debounce="blur"
                    />
                  <% "basic_auth" -> %>
                    <.input
                      field={auth[:username]}
                      type="text"
                      label="Username"
                      required
                      force_errors={@submitted?}
                      phx-debounce="blur"
                    />
                    <.input
                      field={auth[:password]}
                      type="password"
                      autocomplete="one-time-code"
                      label="Password"
                      required={@action == :new}
                      force_errors={@submitted?}
                      placeholder={if @has_secrets[:auth], do: "Leave blank to keep current"}
                      phx-debounce="blur"
                    />
                  <% _ -> %>
                <% end %>
              </.inputs_for>
            <% @selected_transport == "kafka" -> %>
              <h4 class="font-semibold mb-3">Kafka Configuration</h4>

              <.input
                field={tc[:topic]}
                type="text"
                label="Topic"
                placeholder="my-events-topic"
                required
                phx-debounce="blur"
              />

              <label class="label">Brokers</label>
              <div class="space-y-2">
                <div :for={{id, value} <- @broker_rows} class="flex gap-2 items-center">
                  <input
                    type="text"
                    name={tc[:brokers].name <> "[#{id}]"}
                    value={value}
                    placeholder="host:port"
                    class="input input-bordered input-sm flex-1"
                    phx-debounce="blur"
                  />
                  <button
                    type="button"
                    phx-click="remove-broker"
                    phx-target={@myself}
                    phx-value-id={id}
                    class="btn btn-ghost btn-sm btn-square"
                  >
                    &times;
                  </button>
                </div>
                <button
                  type="button"
                  phx-click="add-broker"
                  phx-target={@myself}
                  class="btn btn-outline btn-xs"
                >
                  + Add Broker
                </button>
              </div>

              <.input
                field={tc[:acks]}
                type="select"
                label="Acknowledgements"
                options={[{"All Replicas", "all"}, {"Leader Only", "leader"}, {"None", "none"}]}
              />

              <.input
                field={tc[:delivery_timeout_ms]}
                type="text"
                label="Delivery Timeout (ms)"
                required
                phx-debounce="blur"
              />

              <.input field={tc[:ssl]} type="checkbox" label="Use TLS" />

              <label class="label mt-2">Custom Kafka Headers</label>
              <div class="space-y-2">
                <div
                  :for={{id, {key, value}} <- @kafka_header_rows}
                  class="flex gap-2 items-center"
                >
                  <input
                    type="text"
                    name={tc[:headers].name <> "_kafka[#{id}][key]"}
                    value={key}
                    placeholder="Header name"
                    class="input input-bordered input-sm flex-1"
                    phx-debounce="blur"
                  />
                  <input
                    type="text"
                    name={tc[:headers].name <> "_kafka[#{id}][value]"}
                    value={value}
                    placeholder="Header value"
                    class="input input-bordered input-sm flex-1"
                    phx-debounce="blur"
                  />
                  <button
                    type="button"
                    phx-click="remove-kafka-header"
                    phx-target={@myself}
                    phx-value-id={id}
                    class="btn btn-ghost btn-sm btn-square"
                  >
                    &times;
                  </button>
                </div>
                <button
                  type="button"
                  phx-click="add-kafka-header"
                  phx-target={@myself}
                  class="btn btn-outline btn-xs"
                >
                  + Add Header
                </button>
              </div>

              <div class="divider my-2"></div>
              <h5 class="font-semibold mb-3">Payload Signing</h5>
              <.input
                field={tc[:signing_secret]}
                type="password"
                autocomplete="one-time-code"
                label="HMAC Signing Secret"
                placeholder={
                  if @has_secrets[:signing_secret],
                    do: "Leave blank to keep current",
                    else: "Leave blank to disable signing"
                }
                phx-debounce="blur"
              />
              <p class="text-xs text-base-content/50 mt-1">
                When set, payloads are signed with HMAC-SHA256. The signature is sent as a
                <code class="text-xs">x-payload-signature</code>
                Kafka header as <code class="text-xs">t=timestamp,v1=hex_digest</code>.
              </p>

              <div class="divider my-2"></div>
              <h5 class="font-semibold mb-3">Connection Security</h5>

              <.inputs_for :let={sec} field={tc[:security]}>
                <.input
                  field={sec[:_union_type]}
                  phx-change="security-type-changed"
                  phx-target={@myself}
                  type="select"
                  label="Security Protocol"
                  options={[
                    {"None", "none"},
                    {"TLS", "tls"},
                    {"SASL", "sasl"},
                    {"SASL + TLS", "sasl_tls"}
                  ]}
                />
                <%= if sec.params["_union_type"] in ["sasl", "sasl_tls"] do %>
                  <.input
                    field={sec[:mechanism]}
                    type="select"
                    label="SASL Mechanism"
                    options={[
                      {"PLAIN", "plain"},
                      {"SCRAM-SHA-256", "scram_sha_256"},
                      {"SCRAM-SHA-512", "scram_sha_512"}
                    ]}
                  />
                  <.input
                    field={sec[:username]}
                    type="text"
                    label="Username"
                    required
                    phx-debounce="blur"
                  />
                  <.input
                    field={sec[:password]}
                    type="password"
                    autocomplete="one-time-code"
                    label="Password"
                    required={@action == :new}
                    placeholder={
                      if @has_secrets[:sasl_password],
                        do: "Leave blank to keep current",
                        else: ""
                    }
                    phx-debounce="blur"
                  />
                <% end %>
              </.inputs_for>
            <% @selected_transport == "grpc" -> %>
              <h4 class="font-semibold mb-3">gRPC Configuration</h4>

              <.input
                field={tc[:endpoint]}
                type="text"
                label="Endpoint"
                placeholder="grpc.example.com:443"
                required
                phx-debounce="blur"
              />
              <.input
                field={tc[:service]}
                type="text"
                label="Service"
                placeholder="mypackage.EventService"
                required
                phx-debounce="blur"
              />
              <.input
                field={tc[:method]}
                type="text"
                label="Method"
                placeholder="DeliverEvent"
                required
                phx-debounce="blur"
              />
              <.input
                field={tc[:proto_definition]}
                type="textarea"
                label="Proto Definition"
                placeholder={"syntax = \"proto3\";\npackage mypackage;\n..."}
                required
                phx-debounce="500"
                rows="10"
              />
              <p class="text-xs text-base-content/50 mt-1">
                Paste the <code class="text-xs">.proto</code> file content. Google well-known types
                (<code class="text-xs">Timestamp</code>, <code class="text-xs">Struct</code>, etc.)
                may be imported.
              </p>
              <.input
                field={tc[:timeout_ms]}
                type="text"
                label="Timeout (ms)"
                required
                phx-debounce="blur"
              />

              <label class="label mt-2">Custom Metadata</label>
              <div class="space-y-2">
                <div
                  :for={{id, {key, value}} <- @grpc_header_rows}
                  class="flex gap-2 items-center"
                >
                  <input
                    type="text"
                    name={tc[:headers].name <> "_grpc[#{id}][key]"}
                    value={key}
                    placeholder="Metadata key"
                    class="input input-bordered input-sm flex-1"
                    phx-debounce="blur"
                  />
                  <input
                    type="text"
                    name={tc[:headers].name <> "_grpc[#{id}][value]"}
                    value={value}
                    placeholder="Metadata value"
                    class="input input-bordered input-sm flex-1"
                    phx-debounce="blur"
                  />
                  <button
                    type="button"
                    phx-click="remove-grpc-header"
                    phx-target={@myself}
                    phx-value-id={id}
                    class="btn btn-ghost btn-sm btn-square"
                  >
                    &times;
                  </button>
                </div>
                <button
                  type="button"
                  phx-click="add-grpc-header"
                  phx-target={@myself}
                  class="btn btn-outline btn-xs"
                >
                  + Add Metadata
                </button>
              </div>

              <div class="divider my-2"></div>
              <h5 class="font-semibold mb-3">Payload Signing</h5>
              <.input
                field={tc[:signing_secret]}
                type="password"
                autocomplete="one-time-code"
                label="HMAC Signing Secret"
                placeholder={
                  if @has_secrets[:signing_secret],
                    do: "Leave blank to keep current",
                    else: "Leave blank to disable signing"
                }
                phx-debounce="blur"
              />
              <p class="text-xs text-base-content/50 mt-1">
                When set, payloads are signed with HMAC-SHA256. The signature is sent as
                <code class="text-xs">x-payload-signature</code>
                metadata as <code class="text-xs">t=timestamp,v1=hex_digest</code>.
              </p>

              <div class="divider my-2"></div>
              <h5 class="font-semibold mb-3">Connection Security</h5>

              <.inputs_for :let={sec} field={tc[:security]}>
                <.input
                  field={sec[:_union_type]}
                  phx-change="security-type-changed"
                  phx-target={@myself}
                  type="select"
                  label="Security Protocol"
                  options={[
                    {"None (H2C)", "none"},
                    {"TLS", "tls"},
                    {"Bearer Token", "bearer_token"},
                    {"Mutual TLS", "mutual_tls"}
                  ]}
                />
                <%= case sec.params["_union_type"] do %>
                  <% "bearer_token" -> %>
                    <.input
                      field={sec[:token]}
                      type="password"
                      autocomplete="one-time-code"
                      label="Bearer Token"
                      required={@action == :new}
                      force_errors={@submitted?}
                      placeholder={
                        if @has_secrets[:grpc_token],
                          do: "Leave blank to keep current",
                          else: ""
                      }
                      phx-debounce="blur"
                    />
                  <% "mutual_tls" -> %>
                    <.input
                      field={sec[:client_cert_pem]}
                      type="textarea"
                      label="Client Certificate (PEM)"
                      required={@action == :new}
                      force_errors={@submitted?}
                      rows="5"
                      placeholder="-----BEGIN CERTIFICATE-----"
                      phx-debounce="blur"
                    />
                    <.input
                      field={sec[:client_key_pem]}
                      type="textarea"
                      label="Client Key (PEM)"
                      required={@action == :new}
                      force_errors={@submitted?}
                      rows="5"
                      placeholder="-----BEGIN PRIVATE KEY-----"
                      phx-debounce="blur"
                    />
                  <% _ -> %>
                <% end %>
              </.inputs_for>
            <% true -> %>
          <% end %>
        </div>
      </.inputs_for>
    </div>
    """
  end

  defp transport_options(selected_transport) do
    available = AshIntegration.Transport.available()

    base =
      [{"HTTP (Webhook)", "http"}] ++
        if(:kafka in available, do: [{"Kafka", "kafka"}], else: []) ++
        if(:grpc in available, do: [{"gRPC (Experimental)", "grpc"}], else: [])

    # Always include the currently selected transport so existing integrations
    # using an unavailable transport still render correctly
    selected_atom = String.to_existing_atom(selected_transport)

    if selected_atom not in available do
      label =
        case selected_atom do
          :kafka -> "Kafka (unavailable)"
          :grpc -> "gRPC (unavailable)"
          other -> "#{other} (unavailable)"
        end

      base ++ [{label, selected_transport}]
    else
      base
    end
  end
end
