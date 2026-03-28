defmodule AshIntegration.Web.OutboundIntegrationLive.Helpers do
  alias AshIntegration.OutboundIntegrations.Info, as: OutboundInfo

  def assign_form_options(socket, form) do
    resource_options = resource_options()
    selected_resource = selected_resource(form, resource_options)
    sample_event_map = sample_event_map(selected_resource, selected_version(form))

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

  defp sample_event_map(nil, _version), do: nil
  defp sample_event_map(_resource, nil), do: nil

  defp sample_event_map(resource_identifier, schema_version) do
    OutboundInfo.sample_event(resource_identifier, schema_version)
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
