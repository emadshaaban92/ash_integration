defmodule AshIntegration.Transports.Grpc.Codec do
  @moduledoc """
  Dynamic protobuf encoder that encodes a payload map against a
  `DescriptorProto` at runtime using `Protobuf.Wire` primitives.
  """

  alias Google.Protobuf.{DescriptorProto, FieldDescriptorProto, FileDescriptorSet}

  @type_map %{
    TYPE_DOUBLE: :double,
    TYPE_FLOAT: :float,
    TYPE_INT64: :int64,
    TYPE_UINT64: :uint64,
    TYPE_INT32: :int32,
    TYPE_FIXED64: :fixed64,
    TYPE_FIXED32: :fixed32,
    TYPE_BOOL: :bool,
    TYPE_STRING: :string,
    TYPE_BYTES: :bytes,
    TYPE_UINT32: :uint32,
    TYPE_SFIXED32: :sfixed32,
    TYPE_SFIXED64: :sfixed64,
    TYPE_SINT32: :sint32,
    TYPE_SINT64: :sint64,
    TYPE_ENUM: :int32
  }

  @doc """
  Encodes a payload map into protobuf binary using the given message descriptor.

  The `context` is the `FileDescriptorSet` used to resolve nested message types.
  """
  @spec encode(map(), {DescriptorProto.t(), FileDescriptorSet.t()}) ::
          {:ok, binary()} | {:error, String.t()}
  def encode(payload, {%DescriptorProto{} = descriptor, %FileDescriptorSet{} = file_desc_set}) do
    iodata = encode_message(payload, descriptor, file_desc_set)
    {:ok, IO.iodata_to_binary(iodata)}
  rescue
    e -> {:error, "Protobuf encoding failed: #{Exception.message(e)}"}
  end

  defp encode_message(payload, %DescriptorProto{field: fields} = descriptor, file_desc_set) do
    map_fields = map_field_names(descriptor)

    for field <- fields, reduce: [] do
      acc ->
        value = lookup_value(payload, field.name)

        if value == nil do
          acc
        else
          if is_map_field?(field, map_fields) do
            acc ++ encode_map_field(field, value, descriptor, file_desc_set)
          else
            acc ++ encode_field(field, value, file_desc_set)
          end
        end
    end
  end

  defp encode_field(%FieldDescriptorProto{label: :LABEL_REPEATED} = field, values, file_desc_set)
       when is_list(values) do
    wire_type = field_wire_type(field)

    if packed?(field) do
      packed_data =
        for v <- values, reduce: [] do
          acc -> acc ++ [encode_scalar_value(field, v)]
        end

      packed_binary = IO.iodata_to_binary(packed_data)
      tag = encode_tag(field.number, 2)
      length_prefix = Protobuf.Wire.Varint.encode(byte_size(packed_binary))
      [tag, length_prefix, packed_binary]
    else
      for v <- values, reduce: [] do
        acc ->
          tag = encode_tag(field.number, wire_type)
          acc ++ [tag | encode_single_value(field, v, file_desc_set)]
      end
    end
  end

  defp encode_field(%FieldDescriptorProto{} = field, value, file_desc_set) do
    wire_type = field_wire_type(field)
    tag = encode_tag(field.number, wire_type)
    [tag | encode_single_value(field, value, file_desc_set)]
  end

  defp encode_single_value(
         %FieldDescriptorProto{type: :TYPE_MESSAGE} = field,
         value,
         file_desc_set
       )
       when is_map(value) do
    {:ok, nested_desc} = find_message(file_desc_set, field.type_name)
    nested_binary = encode_message(value, nested_desc, file_desc_set) |> IO.iodata_to_binary()
    length_prefix = Protobuf.Wire.Varint.encode(byte_size(nested_binary))
    [length_prefix, nested_binary]
  end

  defp encode_single_value(%FieldDescriptorProto{} = field, value, _file_desc_set) do
    [encode_scalar_value(field, value)]
  end

  defp encode_scalar_value(%FieldDescriptorProto{type: type}, value) do
    wire_atom = Map.fetch!(@type_map, type)
    Protobuf.Wire.encode(wire_atom, coerce_value(wire_atom, value))
  end

  defp encode_map_field(field, value, descriptor, file_desc_set) when is_map(value) do
    # Map fields are represented as repeated message fields with key/value entries
    {:ok, entry_desc} = find_nested_type(descriptor, field.type_name)
    [key_field, value_field] = Enum.sort_by(entry_desc.field, & &1.number)
    # length-delimited
    wire_type = 2

    for {k, v} <- value, reduce: [] do
      acc ->
        entry_data =
          encode_field(key_field, to_string(k), file_desc_set) ++
            encode_field(value_field, v, file_desc_set)

        entry_binary = IO.iodata_to_binary(entry_data)
        tag = encode_tag(field.number, wire_type)
        length_prefix = Protobuf.Wire.Varint.encode(byte_size(entry_binary))
        acc ++ [tag, length_prefix, entry_binary]
    end
  end

  defp encode_tag(field_number, wire_type) do
    Protobuf.Wire.Varint.encode(Bitwise.bor(Bitwise.bsl(field_number, 3), wire_type))
  end

  defp field_wire_type(%FieldDescriptorProto{type: :TYPE_MESSAGE}), do: 2

  defp field_wire_type(%FieldDescriptorProto{type: type}) do
    wire_atom = Map.fetch!(@type_map, type)
    Protobuf.Wire.wire_type(wire_atom)
  end

  defp packed?(%FieldDescriptorProto{label: :LABEL_REPEATED, type: type}) do
    type not in [:TYPE_STRING, :TYPE_BYTES, :TYPE_MESSAGE]
  end

  defp packed?(_), do: false

  defp coerce_value(:int32, v) when is_float(v), do: trunc(v)
  defp coerce_value(:int64, v) when is_float(v), do: trunc(v)
  defp coerce_value(:uint32, v) when is_float(v), do: trunc(v)
  defp coerce_value(:uint64, v) when is_float(v), do: trunc(v)
  defp coerce_value(:sint32, v) when is_float(v), do: trunc(v)
  defp coerce_value(:sint64, v) when is_float(v), do: trunc(v)
  defp coerce_value(:fixed32, v) when is_float(v), do: trunc(v)
  defp coerce_value(:fixed64, v) when is_float(v), do: trunc(v)
  defp coerce_value(:sfixed32, v) when is_float(v), do: trunc(v)
  defp coerce_value(:sfixed64, v) when is_float(v), do: trunc(v)
  defp coerce_value(_type, v), do: v

  defp lookup_value(payload, field_name) do
    Map.get(payload, field_name) || Map.get(payload, String.to_existing_atom(field_name))
  rescue
    ArgumentError -> nil
  end

  # Map fields in proto3 are represented as nested message types with
  # options.map_entry == true. The field type_name references the entry type.
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
