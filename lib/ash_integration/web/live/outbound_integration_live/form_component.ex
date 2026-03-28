defmodule AshIntegration.Web.OutboundIntegrationLive.FormComponent do
  use Phoenix.Component

  import AshIntegration.Web.Components

  attr :form, :any, required: true
  attr :resource_options, :list, required: true
  attr :action_options, :list, required: true
  attr :schema_version_options, :list, required: true
  attr :sample_event, :string, default: nil
  attr :transform_preview, :any, default: nil
  attr :actor, :any, default: nil
  attr :header_rows, :list, default: []

  def integration_form_fields(assigns) do
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
      </div>

      <.inputs_for :let={tc} field={@form[:transport_config]}>
        <div class="card card-border border-base-300 p-4 mt-4">
          <h4 class="font-semibold mb-3">HTTP Configuration</h4>
          <.input
            field={tc[:method]}
            type="select"
            label="HTTP Method"
            options={[{"POST", "post"}, {"PUT", "put"}, {"PATCH", "patch"}, {"DELETE", "delete"}]}
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
                phx-value-id={id}
                class="btn btn-ghost btn-sm btn-square"
              >
                &times;
              </button>
            </div>
            <button type="button" phx-click="add-header" class="btn btn-outline btn-xs">
              + Add Header
            </button>
          </div>

          <div class="divider my-2"></div>
          <h5 class="font-semibold mb-3">Webhook Signing</h5>
          <.input
            field={tc[:signing_secret]}
            type="password"
            autocomplete="one-time-code"
            label="HMAC Signing Secret"
            placeholder="Leave blank to disable signing"
            phx-debounce="blur"
          />
          <p class="text-xs text-base-content/50 mt-1">
            When set, payloads are signed with HMAC-SHA256. The signature is sent in the
            <code class="text-xs">x-webhook-signature</code>
            header as <code class="text-xs">t=timestamp,v1=hex_digest</code>.
          </p>

          <div class="divider my-2"></div>
          <h5 class="font-semibold mb-3">Authentication</h5>

          <.inputs_for :let={auth} field={tc[:auth]}>
            <.input
              field={auth[:_union_type]}
              phx-change="auth-type-changed"
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
                  required
                  phx-debounce="blur"
                />
              <% "api_key" -> %>
                <.input
                  field={auth[:header_name]}
                  type="text"
                  label="Header Name"
                  required
                  phx-debounce="blur"
                />
                <.input
                  field={auth[:value]}
                  type="password"
                  autocomplete="one-time-code"
                  label="API Key Value"
                  required
                  phx-debounce="blur"
                />
              <% "basic_auth" -> %>
                <.input
                  field={auth[:username]}
                  type="text"
                  label="Username"
                  required
                  phx-debounce="blur"
                />
                <.input
                  field={auth[:password]}
                  type="password"
                  autocomplete="one-time-code"
                  label="Password"
                  required
                  phx-debounce="blur"
                />
              <% _ -> %>
            <% end %>
          </.inputs_for>
        </div>
      </.inputs_for>
    </div>
    """
  end
end
