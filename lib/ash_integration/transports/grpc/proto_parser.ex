defmodule AshIntegration.Transports.Grpc.ProtoParser do
  @moduledoc """
  Parses proto definitions via `protoc` and resolves service/method/message types.

  Used by `ProtoValidator` to validate transform output against proto schemas.

  Part of the **experimental** gRPC transport. Interface may change.
  """

  @doc """
  Parses a proto definition via `protoc` and returns a `FileDescriptorSet`.
  """
  @spec parse(String.t()) :: {:ok, Google.Protobuf.FileDescriptorSet.t()} | {:error, String.t()}
  def parse(proto_definition) do
    run_protoc(proto_definition)
  end

  @doc """
  Resolves the input message `DescriptorProto` for a given service and method.
  """
  @spec resolve_input_type(Google.Protobuf.FileDescriptorSet.t(), String.t(), String.t()) ::
          {:ok, {Google.Protobuf.DescriptorProto.t(), Google.Protobuf.FileDescriptorSet.t()}}
          | {:error, String.t()}
  def resolve_input_type(%Google.Protobuf.FileDescriptorSet{} = descriptor_set, service, method) do
    with {:ok, service_desc} <- find_service(descriptor_set, service),
         {:ok, method_desc} <- find_method(service_desc, method),
         {:ok, input_desc} <- find_message(descriptor_set, method_desc.input_type) do
      {:ok, {input_desc, descriptor_set}}
    end
  end

  # --- Private ---

  defp run_protoc(proto_definition) do
    case System.find_executable("protoc") do
      nil ->
        {:error,
         "protoc (Protocol Buffer compiler) is not available on PATH. " <>
           "Install protoc v3+ for proto field validation."}

      _protoc_path ->
        do_run_protoc(proto_definition)
    end
  end

  defp do_run_protoc(proto_definition) do
    tmp_dir = System.tmp_dir!()
    proto_path = Path.join(tmp_dir, "ash_grpc_#{:erlang.unique_integer([:positive])}.proto")
    desc_path = proto_path <> ".desc"

    try do
      File.write!(proto_path, proto_definition)

      case System.cmd(
             "protoc",
             ["--descriptor_set_out=#{desc_path}", "--proto_path=#{tmp_dir}", proto_path],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          desc_binary = File.read!(desc_path)
          descriptor_set = Google.Protobuf.FileDescriptorSet.decode(desc_binary)
          {:ok, descriptor_set}

        {output, _exit_code} ->
          {:error, "Proto parsing failed: #{String.trim(output)}"}
      end
    after
      File.rm(proto_path)
      File.rm(desc_path)
    end
  end

  defp find_service(%Google.Protobuf.FileDescriptorSet{file: files}, service_name) do
    bare_name = service_name |> String.split(".") |> List.last()

    Enum.find_value(
      files,
      {:error, "Service '#{service_name}' not found in proto definition"},
      fn file ->
        Enum.find_value(file.service, nil, fn svc ->
          full_name =
            if file.package && file.package != "",
              do: "#{file.package}.#{svc.name}",
              else: svc.name

          if svc.name == bare_name || full_name == service_name do
            {:ok, svc}
          end
        end)
      end
    )
  end

  defp find_method(
         %Google.Protobuf.ServiceDescriptorProto{method: methods, name: svc_name},
         method_name
       ) do
    case Enum.find(methods, &(&1.name == method_name)) do
      nil -> {:error, "Method '#{method_name}' not found on service '#{svc_name}'"}
      method -> {:ok, method}
    end
  end

  defp find_message(%Google.Protobuf.FileDescriptorSet{file: files}, type_name) do
    bare_name = type_name |> String.trim_leading(".")

    Enum.find_value(
      files,
      {:error, "Message type '#{type_name}' not found in proto definition"},
      fn file ->
        package = file.package || ""

        Enum.find_value(file.message_type, nil, fn msg ->
          full_name = if package != "", do: "#{package}.#{msg.name}", else: msg.name

          if full_name == bare_name || msg.name == bare_name do
            {:ok, msg}
          end
        end)
      end
    )
  end
end
