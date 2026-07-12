defmodule AshIntegration.Web.Outbound.ConnectionLive.FormComponent do
  @moduledoc false
  # Connection form: name + owner + transport (transport_config) + signing. The
  # transport/auth/security/header/broker machinery lives in the shared
  # `TransportConfig` component and transport-related `Helpers`. The event
  # type/version/transform fields live on the Subscription, not here.
  use AshIntegration.Web, :live_component

  alias AshIntegration.Web.Outbound.Helpers
  alias AshIntegration.Web.Outbound.TransportConfig

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id, :actor, :action, :connection, :navigate]))
    socket = if socket.assigns[:form], do: socket, else: init_form(socket)
    {:ok, socket}
  end

  defp init_form(%{assigns: %{action: :new, actor: actor}} = socket) do
    form =
      AshPhoenix.Form.for_create(AshIntegration.connection_resource(), :create,
        actor: actor,
        forms: [auto?: true]
      )
      |> AshPhoenix.Form.add_form("form[transport_config]", params: %{"_union_type" => "http"})
      |> Helpers.ensure_auth_subform()
      |> Helpers.ensure_signing_subform()

    assign(socket,
      form: form,
      header_rows: [],
      broker_rows: [],
      kafka_header_rows: [],
      has_secrets: %{},
      submitted?: false,
      header_warnings: [],
      selected_transport: "http"
    )
  end

  defp init_form(%{assigns: %{action: :edit, connection: connection, actor: actor}} = socket) do
    form =
      AshPhoenix.Form.for_update(connection, :update, actor: actor, forms: [auto?: true])

    # auth is a subform on HttpConfig only; KafkaConfig has security. Branch on
    # the connection's transport type exactly like the transport-type-changed
    # handler does, then ensure signing for both (it applies to every transport).
    type = transport_type(connection.transport_config)

    form =
      case type do
        "http" -> Helpers.ensure_auth_subform(form)
        "email" -> Helpers.ensure_email_adapter_subform(form)
        "whatsapp" -> Helpers.ensure_whatsapp_adapter_subform(form)
        _ -> Helpers.ensure_security_subform(form)
      end
      |> maybe_ensure_signing(type)

    {header_rows, broker_rows, kafka_header_rows} =
      existing_rows(connection.transport_config)

    socket
    |> assign(
      form: form,
      header_rows: header_rows,
      broker_rows: broker_rows,
      kafka_header_rows: kafka_header_rows,
      submitted?: false,
      header_warnings: [],
      selected_transport: transport_type(connection.transport_config),
      has_secrets: Helpers.detect_existing_secrets(connection)
    )
  end

  defp existing_rows(%Ash.Union{type: :http, value: config}),
    do: {kv_rows(config.headers), [], []}

  defp existing_rows(%Ash.Union{type: :kafka, value: config}),
    do: {[], broker_rows(config.brokers), kv_rows(config.headers)}

  defp existing_rows(%Ash.Union{type: :email, value: config}),
    do: {kv_rows(config.headers), [], []}

  # WhatsApp carries no custom wire headers or brokers.
  defp existing_rows(%Ash.Union{type: :whatsapp}), do: {[], [], []}

  defp existing_rows(_), do: {[], [], []}

  defp kv_rows(headers),
    do: Enum.map(headers || %{}, fn {k, v} -> {System.unique_integer([:positive]), {k, v}} end)

  defp broker_rows(brokers),
    do: Enum.map(brokers || [], fn b -> {System.unique_integer([:positive]), b} end)

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    # Warnings come from the RAW params, before inject_headers_map/1 drops blank-key
    # rows and collapses duplicate keys — otherwise the data loss is invisible.
    warnings = Helpers.header_warnings(params)
    params = params |> Helpers.inject_headers_map() |> Helpers.strip_blank_secrets()

    {:noreply,
     assign(socket,
       form: AshPhoenix.Form.validate(socket.assigns.form, params),
       header_warnings: warnings
     )}
  end

  def handle_event("save", %{"form" => params}, socket) do
    warnings = Helpers.header_warnings(params)
    params = params |> Helpers.inject_headers_map() |> Helpers.strip_blank_secrets()

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, record} ->
        notify_parent({:saved, record})

        {:noreply,
         socket
         |> put_flash(:info, success_message(socket.assigns.action))
         |> push_navigate(to: socket.assigns.navigate)}

      {:error, form} ->
        {:noreply, assign(socket, form: form, submitted?: true, header_warnings: warnings)}
    end
  end

  def handle_event("transport-type-changed", %{"transport_selector" => new_type}, socket) do
    form =
      socket.assigns.form
      |> AshPhoenix.Form.remove_form("form[transport_config]")
      |> AshPhoenix.Form.add_form("form[transport_config]", params: %{"_union_type" => new_type})

    form =
      case new_type do
        "http" -> Helpers.ensure_auth_subform(form)
        "email" -> Helpers.ensure_email_adapter_subform(form)
        "whatsapp" -> Helpers.ensure_whatsapp_adapter_subform(form)
        _ -> Helpers.ensure_security_subform(form)
      end
      |> maybe_ensure_signing(new_type)

    {:noreply,
     assign(socket,
       form: form,
       selected_transport: new_type,
       header_rows: [],
       broker_rows: [],
       kafka_header_rows: [],
       header_warnings: [],
       has_secrets: %{
         signing: false,
         auth: false,
         sasl_password: false,
         smtp_password: false,
         oauth2: false,
         access_token: false
       }
     )}
  end

  def handle_event("add-header", _, socket),
    do: {:noreply, add_row(socket, :header_rows, {"", ""})}

  def handle_event("remove-header", %{"id" => id}, socket),
    do: {:noreply, remove_row(socket, :header_rows, id)}

  def handle_event("add-broker", _, socket),
    do: {:noreply, add_row(socket, :broker_rows, "")}

  def handle_event("remove-broker", %{"id" => id}, socket),
    do: {:noreply, remove_row(socket, :broker_rows, id)}

  def handle_event("add-kafka-header", _, socket),
    do: {:noreply, add_row(socket, :kafka_header_rows, {"", ""})}

  def handle_event("remove-kafka-header", %{"id" => id}, socket),
    do: {:noreply, remove_row(socket, :kafka_header_rows, id)}

  def handle_event("auth-type-changed", params, socket),
    do: union_type_changed(socket, params, :auth)

  def handle_event("security-type-changed", params, socket),
    do: union_type_changed(socket, params, :sasl_password)

  def handle_event("adapter-type-changed", %{"_target" => path} = params, socket) do
    {:noreply, socket} = union_type_changed(socket, params, :smtp_password)

    form =
      if get_in(params, path) == "ms_graph" do
        Helpers.ensure_ms_graph_oauth2_subform(socket.assigns.form)
      else
        socket.assigns.form
      end

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("signing-type-changed", params, socket),
    do: union_type_changed(socket, params, :signing)

  defp union_type_changed(socket, %{"_target" => path} = params, secret_key) do
    new_type = get_in(params, path)
    form_path = :lists.droplast(path)

    form =
      socket.assigns.form
      |> AshPhoenix.Form.remove_form(form_path)
      |> AshPhoenix.Form.add_form(form_path, params: %{"_union_type" => new_type})

    has_secrets = Map.put(socket.assigns[:has_secrets] || %{}, secret_key, false)
    {:noreply, assign(socket, form: form, has_secrets: has_secrets)}
  end

  defp add_row(socket, key, empty) do
    id = System.unique_integer([:positive])
    assign(socket, key, socket.assigns[key] ++ [{id, empty}])
  end

  defp remove_row(socket, key, id) do
    id = String.to_integer(id)
    assign(socket, key, Enum.reject(socket.assigns[key], fn {row_id, _} -> row_id == id end))
  end

  defp transport_type(%Ash.Union{type: type}), do: to_string(type)
  defp transport_type(_), do: "http"

  # Payload signing applies to HTTP and Kafka; email and WhatsApp have no signing
  # scheme (nothing on the receiving end verifies an HMAC).
  defp maybe_ensure_signing(form, type) when type in ["email", "whatsapp"], do: form
  defp maybe_ensure_signing(form, _type), do: Helpers.ensure_signing_subform(form)

  defp success_message(:new), do: "Connection created"
  defp success_message(:edit), do: "Connection updated"

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
          <.form_error_summary :if={@submitted?} errors={Helpers.form_errors(@form)} />
          <.header_warning_banner warnings={@header_warnings} />

          <.input field={f[:name]} type="text" label="Name" required phx-debounce="blur" />

          <.live_component
            id="select-owner_id"
            module={AshIntegration.Web.Components.BelongsToInput}
            label="Owner"
            relationship={
              Ash.Resource.Info.relationship(AshIntegration.connection_resource(), :owner)
            }
            form={f}
            actor={@actor}
          />

          <div class="mt-2">
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

          <.inputs_for :let={tc} field={f[:transport_config]}>
            <TransportConfig.transport_config
              tc={tc}
              selected_transport={@selected_transport}
              action={@action}
              has_secrets={@has_secrets}
              submitted?={@submitted?}
              header_rows={@header_rows}
              broker_rows={@broker_rows}
              kafka_header_rows={@kafka_header_rows}
              myself={@myself}
            />

            <div
              :if={@selected_transport not in ["email", "whatsapp"]}
              class="card card-border border-base-300 p-4 mt-4"
            >
              <h4 class="font-semibold mb-3">Payload Signing</h4>
              <.inputs_for :let={sig} field={tc[:signing]}>
                <.input
                  field={sig[:_union_type]}
                  phx-change="signing-type-changed"
                  phx-target={@myself}
                  type="select"
                  label="Signing Scheme"
                  options={[
                    {"None", "none"},
                    {"Stripe (HMAC-SHA256)", "stripe"},
                    {"Custom (script)", "custom"}
                  ]}
                />
                <%= case sig.params["_union_type"] do %>
                  <% "stripe" -> %>
                    <.input
                      field={sig[:secret]}
                      type="password"
                      autocomplete="one-time-code"
                      label="Signing Secret"
                      required={@action == :new}
                      force_errors={@submitted?}
                      placeholder={if @has_secrets[:signing], do: "Leave blank to keep current"}
                      phx-debounce="blur"
                    />
                    <.input
                      field={sig[:header_name]}
                      type="text"
                      label="Header Name"
                      required
                      force_errors={@submitted?}
                      phx-debounce="blur"
                    />
                  <% "custom" -> %>
                    <.input
                      field={sig[:secret]}
                      type="password"
                      autocomplete="one-time-code"
                      label="Signing Secret"
                      required={@action == :new}
                      force_errors={@submitted?}
                      placeholder={if @has_secrets[:signing], do: "Leave blank to keep current"}
                      phx-debounce="blur"
                    />
                    <.input
                      field={sig[:source]}
                      type="textarea"
                      label="Signing Script"
                      rows="8"
                      force_errors={@submitted?}
                      placeholder="function string_to_sign(ctx) ... end"
                      phx-debounce="blur"
                    />
                    <div class="flex gap-2">
                      <.input
                        field={sig[:algorithm]}
                        type="select"
                        label="Algorithm"
                        options={[{"SHA-256", "sha256"}, {"SHA-1", "sha1"}, {"SHA-512", "sha512"}]}
                      />
                      <.input
                        field={sig[:encoding]}
                        type="select"
                        label="Encoding"
                        options={[{"Hex", "hex"}, {"Base64", "base64"}, {"Base64 URL", "base64url"}]}
                      />
                    </div>
                  <% _ -> %>
                <% end %>
              </.inputs_for>
            </div>
          </.inputs_for>
        </div>

        <div class="modal-action">
          <button type="button" class="btn" phx-click={JS.navigate(@navigate)}>Cancel</button>
          <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
            {if @action == :new, do: "Create", else: "Save Changes"}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp transport_options(selected_transport) do
    available = AshIntegration.Transport.Utils.available()

    base =
      [{"HTTP (Webhook)", "http"}] ++
        if(:kafka in available, do: [{"Kafka", "kafka"}], else: []) ++
        if(:email in available, do: [{"Email (SMTP)", "email"}], else: []) ++
        if(:whatsapp in available, do: [{"WhatsApp", "whatsapp"}], else: [])

    selected_atom = String.to_existing_atom(selected_transport)

    if selected_atom in available do
      base
    else
      base ++ [{"#{selected_transport} (unavailable)", selected_transport}]
    end
  end
end
