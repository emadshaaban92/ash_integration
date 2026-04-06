defmodule AshIntegration.Transports.Grpc.ProtoValidator do
  @moduledoc """
  Validates a transform output map against a proto DescriptorProto.

  Returns `{errors, warnings}` where errors are type mismatches that will
  fail at encoding, and warnings are missing/extra fields.
  """

  alias Google.Protobuf.{DescriptorProto, FieldDescriptorProto, FileDescriptorSet}
  alias AshIntegration.Transports.Grpc.ProtoRegistry

  @type result :: {errors :: [String.t()], warnings :: [String.t()]}

  @integer_types [
    :TYPE_INT32,
    :TYPE_INT64,
    :TYPE_UINT32,
    :TYPE_UINT64,
    :TYPE_SINT32,
    :TYPE_SINT64,
    :TYPE_FIXED32,
    :TYPE_FIXED64,
    :TYPE_SFIXED32,
    :TYPE_SFIXED64
  ]

  @float_types [:TYPE_DOUBLE, :TYPE_FLOAT]

  @doc """
  Validates `output` against the input message type for the given service/method.
  Uses ProtoRegistry to parse the proto definition and resolve the input type.
  """
  @spec validate(map(), String.t(), map()) :: result
  def validate(output, proto_definition, %{service: service, method: method} = _grpc_config) do
    with {:ok, descriptor_set} <- ProtoRegistry.get_or_parse("_validation", proto_definition),
         {:ok, {input_desc, file_desc_set}} <-
           ProtoRegistry.resolve_input_type(descriptor_set, service, method) do
      validate_message(output, input_desc, file_desc_set, [])
    else
      {:error, reason} -> {["Proto parsing error: #{reason}"], []}
    end
  end

  defp validate_message(output, %DescriptorProto{} = descriptor, file_desc_set, path)
       when is_map(output) do
    map_fields = map_field_names(descriptor)
    field_names = MapSet.new(descriptor.field, & &1.name)
    output_keys = MapSet.new(Map.keys(output), &to_string/1)

    # Check for extra fields in output
    extra_warnings =
      output_keys
      |> MapSet.difference(field_names)
      |> Enum.map(fn name ->
        "Extra field '#{format_path(path, name)}' — will be dropped"
      end)

    # Check for missing fields in output
    missing_warnings =
      field_names
      |> MapSet.difference(output_keys)
      |> Enum.map(fn name ->
        field = Enum.find(descriptor.field, &(&1.name == name))
        default = default_value_text(field)

        "Missing field '#{format_path(path, name)}' (#{type_name(field)}) — will default to #{default}"
      end)

    # Validate each field that is present
    {field_errors, field_warnings} =
      descriptor.field
      |> Enum.reduce({[], []}, fn field, {errs, warns} ->
        value = lookup_value(output, field.name)

        if value == nil do
          {errs, warns}
        else
          if is_map_field?(field, map_fields) do
            {e, w} = validate_map_field(field, value, descriptor, file_desc_set, path)
            {errs ++ e, warns ++ w}
          else
            {e, w} = validate_field(field, value, file_desc_set, path)
            {errs ++ e, warns ++ w}
          end
        end
      end)

    {field_errors, extra_warnings ++ missing_warnings ++ field_warnings}
  end

  defp validate_message(_output, %DescriptorProto{}, _file_desc_set, path) do
    {["Type mismatch at '#{format_path(path)}': expected a map for message type, got non-map"],
     []}
  end

  defp validate_field(
         %FieldDescriptorProto{label: :LABEL_REPEATED} = field,
         value,
         file_desc_set,
         path
       ) do
    field_path = path ++ [field.name]

    if is_list(value) do
      value
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {elem, idx}, {errs, warns} ->
        elem_path = field_path ++ ["[#{idx}]"]
        {e, w} = validate_single_value(field, elem, file_desc_set, elem_path)
        {errs ++ e, warns ++ w}
      end)
    else
      {[
         "Type mismatch at '#{format_path(field_path)}': expected a list for repeated field, got #{type_of(value)}"
       ], []}
    end
  end

  defp validate_field(%FieldDescriptorProto{} = field, value, file_desc_set, path) do
    validate_single_value(field, value, file_desc_set, path ++ [field.name])
  end

  defp validate_single_value(
         %FieldDescriptorProto{type: :TYPE_MESSAGE} = field,
         value,
         file_desc_set,
         path
       ) do
    if is_map(value) do
      case find_message(file_desc_set, field.type_name) do
        {:ok, nested_desc} ->
          validate_message(value, nested_desc, file_desc_set, path)

        {:error, reason} ->
          {["Cannot resolve message type '#{field.type_name}': #{reason}"], []}
      end
    else
      {[
         "Type mismatch at '#{format_path(path)}': expected a map for message type '#{short_type(field.type_name)}', got #{type_of(value)}"
       ], []}
    end
  end

  defp validate_single_value(
         %FieldDescriptorProto{type: type} = field,
         value,
         _file_desc_set,
         path
       )
       when type in @integer_types do
    cond do
      is_integer(value) -> {[], []}
      is_float(value) && value == Float.round(value) -> {[], []}
      true -> {[type_error(path, type_name(field), value)], []}
    end
  end

  defp validate_single_value(
         %FieldDescriptorProto{type: type} = field,
         value,
         _file_desc_set,
         path
       )
       when type in @float_types do
    if is_number(value) do
      {[], []}
    else
      {[type_error(path, type_name(field), value)], []}
    end
  end

  defp validate_single_value(
         %FieldDescriptorProto{type: :TYPE_BOOL} = field,
         value,
         _file_desc_set,
         path
       ) do
    if is_boolean(value) do
      {[], []}
    else
      {[type_error(path, type_name(field), value)], []}
    end
  end

  defp validate_single_value(
         %FieldDescriptorProto{type: type} = field,
         value,
         _file_desc_set,
         path
       )
       when type in [:TYPE_STRING, :TYPE_BYTES] do
    if is_binary(value) do
      {[], []}
    else
      {[type_error(path, type_name(field), value)], []}
    end
  end

  defp validate_single_value(
         %FieldDescriptorProto{type: :TYPE_ENUM} = field,
         value,
         _file_desc_set,
         path
       ) do
    if is_binary(value) || is_integer(value) do
      {[], []}
    else
      {[type_error(path, type_name(field), value)], []}
    end
  end

  defp validate_single_value(_field, _value, _file_desc_set, _path) do
    {[], []}
  end

  defp validate_map_field(field, value, descriptor, file_desc_set, path) do
    field_path = path ++ [field.name]

    if is_map(value) do
      {:ok, entry_desc} = find_nested_type(descriptor, field.type_name)
      [key_field, value_field] = Enum.sort_by(entry_desc.field, & &1.number)

      Enum.reduce(value, {[], []}, fn {k, v}, {errs, warns} ->
        entry_path = field_path ++ ["[#{k}]"]

        {ke, kw} =
          validate_single_value(key_field, to_string(k), file_desc_set, entry_path ++ ["key"])

        {ve, vw} = validate_single_value(value_field, v, file_desc_set, entry_path ++ ["value"])

        {errs ++ ke ++ ve, warns ++ kw ++ vw}
      end)
    else
      {[
         "Type mismatch at '#{format_path(field_path)}': expected a map for map field, got #{type_of(value)}"
       ], []}
    end
  end

  # --- Helpers ---

  defp type_error(path, expected_type, value) do
    "Type mismatch at '#{format_path(path)}': expected #{expected_type}, got #{type_of(value)} #{inspect_short(value)}"
  end

  defp format_path([]), do: "root"
  defp format_path(path) when is_list(path), do: Enum.join(path, ".")
  defp format_path(path, name), do: format_path(path ++ [name])

  defp type_of(v) when is_integer(v), do: "integer"
  defp type_of(v) when is_float(v), do: "float"
  defp type_of(v) when is_binary(v), do: "string"
  defp type_of(v) when is_boolean(v), do: "boolean"
  defp type_of(v) when is_map(v), do: "map"
  defp type_of(v) when is_list(v), do: "list"
  defp type_of(v) when is_nil(v), do: "nil"
  defp type_of(_), do: "unknown"

  defp inspect_short(v) when is_binary(v) and byte_size(v) > 50 do
    "\"#{String.slice(v, 0, 50)}...\""
  end

  defp inspect_short(v), do: inspect(v)

  defp type_name(%FieldDescriptorProto{type: :TYPE_MESSAGE, type_name: tn}), do: short_type(tn)

  defp type_name(%FieldDescriptorProto{type: :TYPE_ENUM, type_name: tn}),
    do: "enum(#{short_type(tn)})"

  defp type_name(%FieldDescriptorProto{type: type}),
    do: type |> Atom.to_string() |> String.trim_leading("TYPE_") |> String.downcase()

  defp short_type(nil), do: "unknown"
  defp short_type(type_name), do: type_name |> String.split(".") |> List.last()

  defp default_value_text(%FieldDescriptorProto{label: :LABEL_REPEATED}), do: "[]"
  defp default_value_text(%FieldDescriptorProto{type: type}) when type in @integer_types, do: "0"
  defp default_value_text(%FieldDescriptorProto{type: type}) when type in @float_types, do: "0.0"
  defp default_value_text(%FieldDescriptorProto{type: :TYPE_BOOL}), do: "false"
  defp default_value_text(%FieldDescriptorProto{type: :TYPE_STRING}), do: "\"\""
  defp default_value_text(%FieldDescriptorProto{type: :TYPE_BYTES}), do: "empty bytes"
  defp default_value_text(%FieldDescriptorProto{type: :TYPE_ENUM}), do: "0 (first enum value)"
  defp default_value_text(%FieldDescriptorProto{type: :TYPE_MESSAGE}), do: "nil"
  defp default_value_text(_), do: "default"

  defp lookup_value(payload, field_name) do
    Map.get(payload, field_name) || Map.get(payload, String.to_existing_atom(field_name))
  rescue
    ArgumentError -> nil
  end

  defp map_field_names(%DescriptorProto{nested_type: nested}) do
    for nt <- nested,
        nt.options && nt.options.map_entry,
        into: MapSet.new() do
      nt.name
    end
  end

  defp is_map_field?(
         %FieldDescriptorProto{type: :TYPE_MESSAGE, label: :LABEL_REPEATED} = field,
         map_fields
       ) do
    entry_name = field.type_name |> String.split(".") |> List.last()
    MapSet.member?(map_fields, entry_name)
  end

  defp is_map_field?(_, _), do: false

  defp find_nested_type(%DescriptorProto{nested_type: nested}, type_name) do
    entry_name = type_name |> String.split(".") |> List.last()

    case Enum.find(nested, &(&1.name == entry_name)) do
      nil -> {:error, "Nested type '#{type_name}' not found"}
      desc -> {:ok, desc}
    end
  end

  defp find_message(%FileDescriptorSet{file: files}, type_name) do
    bare_name = type_name |> String.trim_leading(".")

    Enum.find_value(files, {:error, "Message type '#{type_name}' not found"}, fn file ->
      package = file.package || ""

      Enum.find_value(file.message_type, nil, fn msg ->
        full_name = if package != "", do: "#{package}.#{msg.name}", else: msg.name

        if full_name == bare_name || msg.name == bare_name do
          {:ok, msg}
        end
      end)
    end)
  end
end
