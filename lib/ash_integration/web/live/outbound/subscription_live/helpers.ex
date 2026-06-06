defmodule AshIntegration.Web.Outbound.SubscriptionLive.Helpers do
  @moduledoc false
  # Form options + transform preview for the subscription form.
  # Event types and versions come from the derived registry catalog; the
  # preview runs the Lua transform against the producer's `example/1` sample
  # wrapped in the event envelope.

  alias AshIntegration.Outbound.Delivery.Resolver
  alias AshIntegration.Outbound.Wire.Envelope
  alias AshIntegration.Outbound.Declare.Registry

  @doc "Event-type options for the select, from the derived catalog."
  def event_type_options do
    Registry.catalog()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&{&1, &1})
  end

  @doc "Version options for an event type (its supported versions)."
  def version_options(nil), do: []

  def version_options(event_type) do
    case Map.get(Registry.catalog(), event_type) do
      %{versions: versions} -> versions |> Enum.sort() |> Enum.map(&{"V#{&1}", &1})
      _ -> []
    end
  end

  @doc """
  The event-first envelope sample for `(event_type, version)`: the producer's
  `example/1` payload (or `%{}` when none) wrapped as the transform sees it.
  """
  def sample_event(event_type, version) do
    %{
      "id" => "01970000-0000-7000-0000-000000000000",
      "type" => event_type,
      "version" => version,
      "event_key" => "sample-event-key",
      "created_at" => "2024-01-15T10:30:00Z",
      "subject" => "sample-subject-id",
      "data" => sample_data(event_type, version)
    }
  end

  defp sample_data(event_type, version) do
    with producer when not is_nil(producer) <- Registry.producer_for(event_type),
         true <- function_exported?(producer, :example, 1),
         %{} = data <- producer.example(version) do
      data
    else
      _ -> %{}
    end
  end

  @doc "Assigns event-type/version options, the sample, and the live preview."
  def assign_form_options(socket, form) do
    event_type = current_value(form, "event_type")
    version = current_version(form)
    sample = if event_type && version, do: sample_event(event_type, version)
    script = current_value(form, "transform_source")
    connection = preview_connection(socket, form)

    Phoenix.Component.assign(socket,
      event_type_options: event_type_options(),
      version_options: version_options(event_type),
      sample_event: sample && Jason.encode!(sample, pretty: true),
      transform_preview:
        transform_preview(script, sample, connection, socket.assigns[:route] || %{})
    )
  end

  @doc """
  Run the transform against the sample through the FULL `Resolver` — the
  same path dispatch uses — so the preview shows the real transport-shaped
  descriptor: the resolved URL/routing and the pre-seeded wire headers (which the
  script can override/remove). The signature and auth are LIVE carve-outs added at
  delivery, so they are NOT part of this design-time descriptor. Returns `nil`
  when there is no sample or no connection to resolve against yet.
  """
  def transform_preview(_script, nil, _connection, _route), do: nil
  def transform_preview(_script, _sample, nil, _route), do: nil

  def transform_preview(script, sample, connection, route) do
    subscription =
      struct(AshIntegration.subscription_resource(),
        transform_source: present(script) || "-- noop",
        route_config: preview_route_config(connection, route)
      )

    case Resolver.resolve(
           connection,
           subscription,
           sample_envelope(sample),
           sample_created_at(sample)
         ) do
      :skip ->
        {:ok, :skip}

      {:ok, descriptor, _body_hash} ->
        {:ok, Jason.encode!(descriptor, pretty: true)}

      {:error, message} ->
        {:error, message}
    end
  end

  # The connection the form is currently targeting (single-connection context, or
  # the one selected from the list), so the preview resolves against its real
  # transport config, base URL, static headers, and signing secret.
  defp preview_connection(socket, form) do
    connections =
      case socket.assigns[:connection] do
        %{} = connection -> [connection]
        _ -> socket.assigns[:connections] || []
      end

    conn_id = to_string(current_value(form, "connection_id"))
    Enum.find(connections, &(to_string(&1.id) == conn_id)) || List.first(connections)
  end

  # A transient route_config (matching the connection's transport) from the form's
  # route inputs, so the resolved URL/topic reflects what's being edited.
  defp preview_route_config(%{transport_config: %Ash.Union{type: :http}}, route) do
    %Ash.Union{
      type: :http,
      value:
        struct(AshIntegration.Outbound.Delivery.Route.HttpRoute,
          path: present(route["path"]),
          method: method_atom(route["method"])
        )
    }
  end

  defp preview_route_config(%{transport_config: %Ash.Union{type: :kafka}}, route) do
    %Ash.Union{
      type: :kafka,
      value:
        struct(AshIntegration.Outbound.Delivery.Route.KafkaRoute, topic: present(route["topic"]))
    }
  end

  defp preview_route_config(_connection, _route), do: nil

  defp sample_envelope(sample) do
    Envelope.transform_input(%{
      id: sample["id"],
      type: sample["type"],
      version: sample["version"],
      event_key: sample["event_key"],
      created_at: sample["created_at"],
      subject: sample["subject"],
      data: sample["data"]
    })
  end

  defp sample_created_at(sample) do
    case DateTime.from_iso8601(to_string(sample["created_at"])) do
      {:ok, datetime, _offset} -> datetime
      _ -> ~U[2024-01-15 10:30:00Z]
    end
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp method_atom(value) when value in [nil, ""], do: nil
  defp method_atom(value), do: String.to_existing_atom(value)

  defp current_value(form, key) do
    Map.get(form.params || %{}, key) || Map.get(form.data || %{}, String.to_existing_atom(key))
  end

  defp current_version(form) do
    case current_value(form, "version") do
      nil -> nil
      "" -> nil
      v when is_binary(v) -> String.to_integer(v)
      v -> v
    end
  end
end
