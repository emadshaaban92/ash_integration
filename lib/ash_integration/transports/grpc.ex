defmodule AshIntegration.Transports.Grpc do
  @moduledoc """
  **Experimental** — gRPC transport via `grpcurl` subprocess.

  This transport shells out to `grpcurl` for each delivery. It works correctly but
  does not use persistent connections or a native Elixir gRPC client. See the
  [gRPC Transport guide](guides/grpc-transport.md) for details on the experimental
  status and known trade-offs.
  """

  @behaviour AshIntegration.Transport

  require Logger

  @impl true
  def deliver(outbound_integration, event_id, _resource_id, payload) do
    %Ash.Union{type: :grpc, value: config} = outbound_integration.transport_config
    json_payload = Jason.encode!(payload)
    integration_id = to_string(outbound_integration.id)

    case System.find_executable("grpcurl") do
      nil ->
        {:error,
         %{
           error_message:
             "grpcurl is not available on PATH. Install grpcurl to use gRPC transport.",
           retryable: false
         }}

      _path ->
        execute_grpcurl(config, event_id, integration_id, json_payload)
    end
  end

  defp execute_grpcurl(config, event_id, integration_id, json_payload) do
    tmp_dir = System.tmp_dir!()
    proto_filename = "ash_grpc_#{integration_id}_#{:erlang.unique_integer([:positive])}.proto"
    proto_path = Path.join(tmp_dir, proto_filename)

    try do
      File.write!(proto_path, config.proto_definition)

      {security_args, extra_temp_files} = security_args(config, tmp_dir)

      try do
        args =
          ["-import-path", tmp_dir, "-proto", proto_filename] ++
            timeout_args(config) ++
            ["-d", json_payload] ++
            security_args ++
            header_args(config, event_id, integration_id, json_payload) ++
            [config.endpoint, "#{config.service}/#{config.method}"]

        timeout_ms = (config.timeout_ms || 30_000) + 5_000

        task =
          Task.async(fn ->
            System.cmd("grpcurl", args, stderr_to_stdout: true)
          end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            {:ok, %{response_status: 200, response_body: String.trim(output)}}

          {:ok, {output, _exit_code}} ->
            trimmed = String.trim(output)
            {retryable, _type} = classify_error(trimmed)
            {:error, %{error_message: trimmed, retryable: retryable}}

          nil ->
            {:error, %{error_message: "grpcurl timed out", retryable: true}}
        end
      after
        Enum.each(extra_temp_files, &File.rm/1)
      end
    after
      File.rm(proto_path)
    end
  end

  defp timeout_args(config) do
    seconds = max(div(config.timeout_ms || 30_000, 1000), 1)
    ["-max-time", to_string(seconds)]
  end

  defp header_args(config, event_id, integration_id, json_payload) do
    custom =
      (config.headers || %{})
      |> Enum.flat_map(fn {k, v} -> ["-H", "#{k}: #{v}"] end)

    signature =
      AshIntegration.PayloadSigning.signature_headers(config, json_payload)
      |> Enum.flat_map(fn {k, v} -> ["-H", "#{k}: #{v}"] end)

    ["-H", "x-event-id: #{event_id}", "-H", "x-integration-id: #{integration_id}"] ++
      custom ++ signature
  end

  defp security_args(%{security: %Ash.Union{type: :none}}, _tmp_dir) do
    {["-plaintext"], []}
  end

  defp security_args(%{security: %Ash.Union{type: :tls}}, _tmp_dir) do
    {[], []}
  end

  defp security_args(%{security: %Ash.Union{type: :bearer_token, value: sec}}, _tmp_dir) do
    {:ok, loaded} = Ash.load(sec, [:token], domain: AshIntegration.domain())
    {["-H", "authorization: Bearer #{loaded.token}"], []}
  end

  defp security_args(%{security: %Ash.Union{type: :mutual_tls, value: mtls}}, tmp_dir) do
    {:ok, loaded} =
      Ash.load(mtls, [:client_cert_pem, :client_key_pem], domain: AshIntegration.domain())

    unique = :erlang.unique_integer([:positive])
    cert_path = Path.join(tmp_dir, "ash_grpc_cert_#{unique}.pem")
    key_path = Path.join(tmp_dir, "ash_grpc_key_#{unique}.pem")

    File.write!(cert_path, loaded.client_cert_pem)
    File.write!(key_path, loaded.client_key_pem)

    {["-cert", cert_path, "-key", key_path], [cert_path, key_path]}
  end

  defp security_args(_, _tmp_dir) do
    {["-plaintext"], []}
  end

  @doc false
  def classify_error(output) do
    cond do
      # gRPC status codes (most specific, check first)
      output =~ "Code: Unavailable" -> {true, :unavailable}
      output =~ "Code: ResourceExhausted" -> {true, :rate_limited}
      output =~ "Code: DeadlineExceeded" -> {true, :timeout}
      output =~ "Code: Internal" -> {true, :internal}
      output =~ "Code: NotFound" -> {false, :not_found}
      output =~ "Code: InvalidArgument" -> {false, :invalid_argument}
      output =~ "Code: PermissionDenied" -> {false, :permission_denied}
      output =~ "Code: Unauthenticated" -> {false, :unauthenticated}
      output =~ "Code: Unimplemented" -> {false, :unimplemented}
      output =~ "Code: AlreadyExists" -> {false, :already_exists}
      output =~ "Code: FailedPrecondition" -> {false, :failed_precondition}
      # Connection-level errors (more generic, check after gRPC codes)
      output =~ "context deadline exceeded" -> {true, :timeout}
      output =~ "connection refused" -> {true, :connection_refused}
      output =~ "connection error" -> {true, :connection_error}
      output =~ "Failed to process proto" -> {false, :proto_error}
      true -> {false, :unknown}
    end
  end

  @doc false
  def grpc_status_to_http(0), do: 200
  def grpc_status_to_http(4), do: 504
  def grpc_status_to_http(8), do: 429
  def grpc_status_to_http(14), do: 503
  def grpc_status_to_http(3), do: 400
  def grpc_status_to_http(5), do: 404
  def grpc_status_to_http(7), do: 403
  def grpc_status_to_http(12), do: 501
  def grpc_status_to_http(16), do: 401
  def grpc_status_to_http(_), do: 500
end
