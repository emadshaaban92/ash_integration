defmodule AshIntegration.Web.Outbound.TransportConfig do
  use Phoenix.Component

  import AshIntegration.Web.Components

  attr(:tc, :any, required: true)
  attr(:selected_transport, :string, required: true)
  attr(:action, :atom, required: true)
  attr(:has_secrets, :map, required: true)
  attr(:submitted?, :boolean, default: false)
  attr(:header_rows, :list, default: [])
  attr(:broker_rows, :list, default: [])
  attr(:kafka_header_rows, :list, default: [])
  attr(:myself, :any, required: true)

  def transport_config(%{selected_transport: "http"} = assigns) do
    ~H"""
    <div class="card card-border border-base-300 p-4 mt-4">
      <h4 class="font-semibold mb-3">HTTP Configuration</h4>
      <p class="text-sm text-base-content/60 mb-3">
        The base URL, auth, and a default timeout live here. Each subscription sets
        its own request path, HTTP method, and (optionally) a timeout override.
      </p>
      <.input
        field={@tc[:base_url]}
        type="text"
        label="Base URL"
        placeholder="https://api.example.com"
        required
        phx-debounce="blur"
      />
      <.input
        field={@tc[:timeout_ms]}
        type="text"
        label="Default timeout (ms)"
        required
        phx-debounce="blur"
      />
      <label class="label">Custom Headers</label>
      <div class="space-y-2">
        <div :for={{id, {key, value}} <- @header_rows} class="flex gap-2 items-center">
          <input
            type="text"
            name={@tc[:headers].name <> "[#{id}][key]"}
            value={key}
            placeholder="Header name"
            class="input input-bordered input-sm flex-1"
            phx-debounce="blur"
          />
          <input
            type="text"
            name={@tc[:headers].name <> "[#{id}][value]"}
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
      <h5 class="font-semibold mb-3">Authentication</h5>

      <.inputs_for :let={auth} field={@tc[:auth]}>
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
    </div>
    """
  end

  def transport_config(%{selected_transport: "kafka"} = assigns) do
    ~H"""
    <div class="card card-border border-base-300 p-4 mt-4">
      <h4 class="font-semibold mb-3">Kafka Configuration</h4>
      <p class="text-sm text-base-content/60 mb-3">
        Brokers, security, and a default topic live here. A subscription may
        override the topic.
      </p>

      <.input
        field={@tc[:topic]}
        type="text"
        label="Default topic"
        placeholder="my-events-topic"
        phx-debounce="blur"
      />

      <label class="label">Brokers</label>
      <div class="space-y-2">
        <div :for={{id, value} <- @broker_rows} class="flex gap-2 items-center">
          <input
            type="text"
            name={@tc[:brokers].name <> "[#{id}]"}
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
        field={@tc[:acks]}
        type="select"
        label="Acknowledgements"
        options={[{"All Replicas", "all"}, {"Leader Only", "leader"}, {"None", "none"}]}
      />

      <label class="label mt-2">Custom Kafka Headers</label>
      <div class="space-y-2">
        <div
          :for={{id, {key, value}} <- @kafka_header_rows}
          class="flex gap-2 items-center"
        >
          <input
            type="text"
            name={@tc[:headers].name <> "_kafka[#{id}][key]"}
            value={key}
            placeholder="Header name"
            class="input input-bordered input-sm flex-1"
            phx-debounce="blur"
          />
          <input
            type="text"
            name={@tc[:headers].name <> "_kafka[#{id}][value]"}
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
      <h5 class="font-semibold mb-3">Connection Security</h5>

      <.inputs_for :let={sec} field={@tc[:security]}>
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
    </div>
    """
  end

  def transport_config(assigns) do
    ~H"""
    <div></div>
    """
  end
end
