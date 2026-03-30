defmodule AshIntegration.Web.OutboundIntegrationLive.Helpers do
  alias AshIntegration.OutboundIntegrations.Info, as: OutboundInfo

  def create_form_defaults do
    resource_options = resource_options()

    case resource_options do
      [{_, identifier} | _] ->
        versions = schema_version_options(identifier)

        version =
          case versions do
            [{_, v} | _] -> v
            _ -> nil
          end

        %{
          "resource" => identifier,
          "schema_version" => version,
          "transform_script" => "result = event"
        }

      _ ->
        %{"transform_script" => "result = event"}
    end
  end

  def assign_form_options(socket, form) do
    resource_options = resource_options()
    selected_resource = selected_resource(form, resource_options)
    selected_action = selected_action(form)
    sample_event_map = sample_event_map(selected_resource, selected_version(form), selected_action)

    script =
      Map.get(form.params || %{}, "transform_script") ||
        Map.get(form.data || %{}, :transform_script)

    Phoenix.Component.assign(socket,
      resource_options: resource_options,
      action_options: action_options(selected_resource),
      schema_version_options: schema_version_options(selected_resource),
      sample_event: encode_sample(sample_event_map),
      transform_preview: transform_preview(script, sample_event_map)
    )
  end

  def ensure_auth_subform(form) do
    tc = form.forms[:transport_config]

    cond do
      is_nil(tc) ->
        form

      is_nil(tc.forms[:auth]) ->
        AshPhoenix.Form.add_form(form, "form[transport_config][auth]",
          params: %{"_union_type" => "none"}
        )

      true ->
        form
    end
  end

  def owner_name(%{owner: %{display_name: dn}}) when is_binary(dn), do: dn
  def owner_name(%{owner: %{name: name}}) when is_binary(name), do: name
  def owner_name(%{owner: %{email: email}}), do: to_string(email)
  def owner_name(_), do: "—"

  def parse_int(nil, default), do: default

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(val, _default) when is_integer(val), do: val

  def humanize(value) when is_atom(value), do: humanize(Atom.to_string(value))

  def humanize(value) when is_binary(value) do
    value
    |> Phoenix.Naming.humanize()
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize(value), do: to_string(value)

  def format_datetime(value, format \\ :short)

  def format_datetime(%DateTime{} = dt, format) do
    case format do
      :short -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      :long -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
    end
  end

  def format_datetime(_, _format), do: "—"

  defp resource_options do
    OutboundInfo.outbound_resources()
    |> Enum.map(fn resource ->
      identifier = OutboundInfo.resource_identifier(resource)
      {humanize(identifier), identifier}
    end)
  end

  defp selected_resource(form, resource_options) do
    Map.get(form.params || %{}, "resource") ||
      Map.get(form.data || %{}, :resource) ||
      case resource_options do
        [{_, identifier} | _] -> identifier
        _ -> nil
      end
  end

  defp action_options(nil), do: []

  defp action_options(resource_identifier) do
    case OutboundInfo.resource_module(resource_identifier) do
      nil ->
        []

      resource ->
        Enum.map(OutboundInfo.actions(resource), &{humanize(&1.name), to_string(&1.name)})
    end
  end

  defp selected_version(form) do
    case Map.get(form.params || %{}, "schema_version") do
      nil -> Map.get(form.data || %{}, :schema_version)
      "" -> nil
      val when is_binary(val) -> String.to_integer(val)
      val -> val
    end
  end

  defp schema_version_options(nil), do: []

  defp schema_version_options(resource_identifier) do
    case OutboundInfo.resource_module(resource_identifier) do
      nil ->
        []

      resource ->
        resource
        |> OutboundInfo.supported_versions()
        |> Enum.map(&{"V#{&1}", &1})
    end
  end

  @encrypted_auth_fields ["token", "value", "password"]

  def strip_blank_secrets(params) do
    case get_in(params, ["transport_config"]) do
      tc when is_map(tc) ->
        tc =
          tc
          |> maybe_drop_blank("signing_secret")
          |> Map.update("auth", %{}, fn auth when is_map(auth) ->
            Enum.reduce(@encrypted_auth_fields, auth, &maybe_drop_blank(&2, &1))
          end)

        put_in(params, ["transport_config"], tc)

      _ ->
        params
    end
  end

  defp maybe_drop_blank(map, key) do
    case Map.get(map, key) do
      val when val in [nil, ""] -> Map.delete(map, key)
      _ -> map
    end
  end

  def detect_existing_secrets(integration) do
    tc = integration.transport_config

    auth_secret =
      case tc && tc.auth do
        %{type: :bearer_token, value: v} -> v.encrypted_token != nil
        %{type: :api_key, value: v} -> v.encrypted_value != nil
        %{type: :basic_auth, value: v} -> v.encrypted_password != nil
        _ -> false
      end

    %{
      signing_secret: tc != nil and tc.encrypted_signing_secret != nil,
      auth: auth_secret
    }
  end

  def inject_headers_map(params) do
    case get_in(params, ["transport_config", "headers"]) do
      raw when is_map(raw) ->
        headers_map =
          raw
          |> Map.values()
          |> Enum.reject(fn entry -> entry["key"] == "" end)
          |> Map.new(fn entry -> {entry["key"], entry["value"] || ""} end)

        put_in(params, ["transport_config", "headers"], headers_map)

      _ ->
        params
    end
  end

  defp selected_action(form) do
    case Map.get(form.params || %{}, "actions") do
      [action | _] when is_binary(action) and action != "" -> action
      _ ->
        case Map.get(form.data || %{}, :actions) do
          [action | _] -> to_string(action)
          _ -> nil
        end
    end
  end

  defp sample_event_map(nil, _version, _action), do: nil
  defp sample_event_map(_resource, nil, _action), do: nil

  defp sample_event_map(resource_identifier, schema_version, action) do
    case OutboundInfo.sample_event_data(resource_identifier, schema_version) do
      nil ->
        nil

      data ->
        OutboundInfo.build_event(%{
          id: "01970000-0000-7000-0000-000000000000",
          resource: resource_identifier,
          action: action || "create",
          schema_version: schema_version,
          occurred_at: "2024-01-15T10:30:00Z",
          data: data
        })
    end
  end

  defp encode_sample(nil), do: nil
  defp encode_sample(map), do: Jason.encode!(map, pretty: true)

  defp transform_preview(nil, _sample), do: nil
  defp transform_preview(_script, nil), do: nil
  defp transform_preview("", _sample), do: nil

  defp transform_preview(script, sample_event_map) do
    case AshIntegration.LuaSandbox.execute(script, sample_event_map) do
      {:ok, :skip} -> {:ok, :skip}
      {:ok, result} -> {:ok, Jason.encode!(result, pretty: true)}
      {:error, message} -> {:error, message}
    end
  end
end
