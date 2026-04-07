defmodule AshIntegration.Validations.GrpcProto do
  @moduledoc """
  Validates that a gRPC config's proto_definition, service, and method are consistent.

  At config save time, uses `grpcurl` to verify:
  1. The proto is syntactically valid
  2. The specified service exists
  3. The specified method exists on that service
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    proto = Ash.Changeset.get_attribute(changeset, :proto_definition)
    service = Ash.Changeset.get_attribute(changeset, :service)
    method = Ash.Changeset.get_attribute(changeset, :method)

    if is_nil(proto) || is_nil(service) || is_nil(method) do
      :ok
    else
      do_validate(proto, service, method)
    end
  end

  defp do_validate(proto, service, method) do
    case System.find_executable("grpcurl") do
      nil ->
        # Fall back to accepting if grpcurl isn't available (validation is best-effort)
        :ok

      _path ->
        validate_with_grpcurl(proto, service, method)
    end
  end

  defp validate_with_grpcurl(proto, service, method) do
    tmp_dir = System.tmp_dir!()
    unique = :erlang.unique_integer([:positive])
    proto_filename = "ash_grpc_validate_#{unique}.proto"
    proto_path = Path.join(tmp_dir, proto_filename)

    try do
      File.write!(proto_path, proto)

      with :ok <- validate_proto_syntax(tmp_dir, proto_filename),
           :ok <- validate_service(tmp_dir, proto_filename, service),
           :ok <- validate_method(tmp_dir, proto_filename, service, method) do
        :ok
      end
    after
      File.rm(proto_path)
    end
  end

  defp validate_proto_syntax(tmp_dir, proto_filename) do
    case System.cmd(
           "grpcurl",
           ["-import-path", tmp_dir, "-proto", proto_filename, "list"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _} ->
        {:error, field: :proto_definition, message: parse_error_message(output)}
    end
  end

  defp validate_service(tmp_dir, proto_filename, service) do
    case System.cmd(
           "grpcurl",
           ["-import-path", tmp_dir, "-proto", proto_filename, "describe", service],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {_output, _} ->
        {:error, field: :service, message: "Service '#{service}' not found in proto definition"}
    end
  end

  defp validate_method(tmp_dir, proto_filename, service, method) do
    case System.cmd(
           "grpcurl",
           [
             "-import-path",
             tmp_dir,
             "-proto",
             proto_filename,
             "describe",
             "#{service}.#{method}"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {_output, _} ->
        {:error, field: :method, message: "Method '#{method}' not found on service '#{service}'"}
    end
  end

  defp parse_error_message(output) do
    trimmed = String.trim(output)

    cond do
      trimmed =~ "syntax error" ->
        case Regex.run(~r/syntax error:.*$/m, trimmed) do
          [match] -> "Proto syntax error: #{match}"
          _ -> "Proto definition is invalid: #{trimmed}"
        end

      trimmed =~ "could not parse" ->
        "Proto definition could not be parsed: #{trimmed}"

      true ->
        "Proto validation failed: #{trimmed}"
    end
  end
end
