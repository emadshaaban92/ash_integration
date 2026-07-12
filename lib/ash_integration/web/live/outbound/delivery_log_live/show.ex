defmodule AshIntegration.Web.Outbound.DeliveryLogLive.Show do
  @moduledoc false
  # One delivery attempt: the request/response of a single transport call. Links
  # up to the EventDelivery it was an attempt of.
  use AshIntegration.Web, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    actor = socket.assigns.current_user

    case Ash.get(AshIntegration.delivery_log_resource(), id,
           actor: actor,
           load: [:event_delivery]
         ) do
      {:ok, log} ->
        {:noreply, assign(socket, log: log, page_title: "Delivery Log")}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Delivery log not found")
         |> push_navigate(to: base() <> "/logs")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:logs} />

      <div class="breadcrumbs text-sm mb-2">
        <ul>
          <li><.link navigate={base() <> "/logs"}>Delivery Logs</.link></li>
          <li>{@log.event_type}</li>
        </ul>
      </div>

      <.page_header>
        Delivery Log
        <:subtitle><.status_badge status={@log.status} /></:subtitle>
      </.page_header>

      <div class="card card-border border-base-300 p-4 mb-4">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
          <.field label="Event Type">
            <.link navigate={path(:event_type, @log.event_type)} class="link link-hover">
              {@log.event_type}
            </.link>
            v{@log.version}
          </.field>
          <.field label="Event Key" mono>{@log.event_key}</.field>
          <.field label="Response Status">{@log.response_status || "—"}</.field>
          <.field label="Duration">{@log.duration_ms && "#{@log.duration_ms} ms"}</.field>
          <.field :if={parent_event_id(@log)} label="Event">
            <.link navigate={base() <> "/events/#{parent_event_id(@log)}"} class="link link-hover">
              View event
            </.link>
          </.field>
          <.field :if={@log.event_delivery_id} label="Delivery">
            <.link
              navigate={base() <> "/deliveries/#{@log.event_delivery_id}"}
              class="link link-hover"
            >
              View delivery
            </.link>
          </.field>
          <.field :if={@log.kafka_partition} label="Kafka Partition">{@log.kafka_partition}</.field>
          <.field :if={@log.kafka_offset} label="Kafka Offset">{@log.kafka_offset}</.field>
        </div>
      </div>

      <div :if={@log.error_message} class="alert alert-error mb-4">
        <.icon name="hero-exclamation-triangle" />
        <span class="font-mono text-sm">{@log.error_message}</span>
      </div>

      <.json_block title="Request Payload" data={@log.request_payload} />
      <.text_block title="Response Body" text={@log.response_body} />
    </div>
    """
  end

  # The immutable Event upstream of this attempt, reached via its EventDelivery.
  # Nil when the delivery (and thus the parent Event link) isn't loadable.
  defp parent_event_id(%{event_delivery: %{event_id: event_id}}) when not is_nil(event_id),
    do: event_id

  defp parent_event_id(_log), do: nil

  defp path(:event_type, type), do: base() <> "/event-types/#{URI.encode(type)}"
  defp base, do: AshIntegration.Web.base_path()
end
