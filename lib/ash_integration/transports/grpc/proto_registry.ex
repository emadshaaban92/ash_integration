defmodule AshIntegration.Transports.Grpc.ProtoRegistry do
  @moduledoc """
  Manages parsing and caching of proto definitions for gRPC integrations.

  Parsed `FileDescriptorSet` structs are cached in ETS keyed by
  `{integration_id, sha256(proto_content)}`. Entries are evicted when
  the proto content changes.
  """

  use GenServer

  @table __MODULE__

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a cached parsed `FileDescriptorSet` or parses the proto definition
  via `protoc` and caches the result.
  """
  @spec get_or_parse(String.t(), String.t()) ::
          {:ok, Google.Protobuf.FileDescriptorSet.t()} | {:error, String.t()}
  def get_or_parse(integration_id, proto_definition) do
    hash = :crypto.hash(:sha256, proto_definition)
    cache_key = {integration_id, hash}

    try do
      case :ets.lookup(@table, cache_key) do
        [{^cache_key, descriptor_set}] ->
          {:ok, descriptor_set}

        [] ->
          evict(integration_id)
          parse_and_cache(cache_key, proto_definition)
      end
    rescue
      ArgumentError ->
        # ETS table not yet created (GenServer not started) — parse without caching
        parse_proto(proto_definition)
    end
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

  @doc """
  Evicts all cached entries for a given integration.
  """
  @spec evict(String.t()) :: :ok
  def evict(integration_id) do
    :ets.match_delete(@table, {{integration_id, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # --- Private ---

  defp parse_and_cache(cache_key, proto_definition) do
    case parse_proto(proto_definition) do
      {:ok, descriptor_set} ->
        :ets.insert(@table, {cache_key, descriptor_set})
        {:ok, descriptor_set}

      {:error, _} = error ->
        error
    end
  end

  defp parse_proto(proto_definition) do
    if Regex.match?(~r/^\s*import\s/m, proto_definition) do
      {:error,
       "Proto definition must be self-contained (no import statements). " <>
         "Inline all message types directly in the proto file."}
    else
      run_protoc(proto_definition)
    end
  end

  defp run_protoc(proto_definition) do
    case System.find_executable("protoc") do
      nil ->
        {:error,
         "protoc (Protocol Buffer compiler) is not available on PATH. Install protoc v3+ to use gRPC transport."}

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
    # Strip leading dot and package prefix for matching
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
    # type_name is fully qualified like ".package.MessageName"
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
