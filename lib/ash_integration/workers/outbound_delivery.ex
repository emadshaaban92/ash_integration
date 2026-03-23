defmodule AshIntegration.Workers.OutboundDelivery do
  use Oban.Worker,
    queue: :integration_delivery,
    max_attempts: 20,
    unique: [keys: [:event_id, :outbound_integration_id]]

  require Logger

  alias AshIntegration.LuaSandbox

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{
          "event_id" => event_id,
          "resource" => resource,
          "action" => action,
          "outbound_integration_id" => outbound_integration_id,
          "resource_id" => resource_id,
          "snapshot" => snapshot
        }
      }) do
    case check_ordering(outbound_integration_id, resource_id, job_id) do
      :ok ->
        execute_delivery(
          outbound_integration_id,
          event_id,
          resource,
          action,
          resource_id,
          snapshot
        )

      {:snooze, seconds} ->
        {:snooze, seconds}
    end
  end

  defp check_ordering(outbound_integration_id, resource_id, job_id) do
    import Ecto.Query

    has_predecessors =
      Oban.Job
      |> where([j], j.queue == "integration_delivery")
      |> where([j], j.state != "completed")
      |> where([j], j.args["outbound_integration_id"] == ^outbound_integration_id)
      |> where([j], j.args["resource_id"] == ^resource_id)
      |> where([j], j.id < ^job_id)
      |> AshIntegration.repo().exists?()

    if has_predecessors, do: {:snooze, 30}, else: :ok
  rescue
    e ->
      Logger.error(
        "Ordering check failed for integration #{outbound_integration_id}: #{inspect(e)}"
      )

      {:error, "Ordering check failed: #{inspect(e)}"}
  end

  defp execute_delivery(
         outbound_integration_id,
         event_id,
         resource,
         action,
         resource_id,
         snapshot
       ) do
    case Ash.get(AshIntegration.outbound_integration_resource(), outbound_integration_id,
           authorize?: false
         ) do
      {:ok, outbound_integration} ->
        if outbound_integration.active do
          run_pipeline(outbound_integration, event_id, resource, action, resource_id, snapshot)
        else
          :ok
        end

      {:error, _} ->
        Logger.warning(
          "Outbound integration #{outbound_integration_id} not found, skipping delivery"
        )

        :ok
    end
  end

  defp run_pipeline(outbound_integration, event_id, resource, action, resource_id, snapshot) do
    case LuaSandbox.execute(outbound_integration.transform_script, snapshot) do
      {:ok, :skip} ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          nil,
          :skipped
        )

        :ok

      {:ok, payload} ->
        deliver_and_log(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload
        )

      {:error, lua_error} ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          nil,
          :failed,
          error_message: "Lua error: #{lua_error}"
        )

        :ok
    end
  end

  defp deliver_and_log(outbound_integration, event_id, resource, action, resource_id, payload) do
    start_time = System.monotonic_time(:millisecond)
    result = deliver_http(outbound_integration, event_id, payload)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, status, body} ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload,
          :success,
          response_status: status,
          response_body: truncate(body, 102_400),
          duration_ms: duration_ms
        )

        record_success(outbound_integration)
        :ok

      {:error, status, body} when is_integer(status) and status >= 500 ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload,
          :failed,
          response_status: status,
          response_body: truncate(body, 102_400),
          duration_ms: duration_ms,
          error_message: "HTTP #{status}"
        )

        record_failure(outbound_integration)
        {:error, "HTTP #{status} - retryable"}

      {:error, status, body} when is_integer(status) ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload,
          :failed,
          response_status: status,
          response_body: truncate(body, 102_400),
          duration_ms: duration_ms,
          error_message: "HTTP #{status}"
        )

        record_failure(outbound_integration)
        :ok

      {:error, reason} ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload,
          :failed,
          duration_ms: duration_ms,
          error_message: "Network error: #{inspect(reason)}"
        )

        record_failure(outbound_integration)
        {:error, "Network error - retryable"}
    end
  end

  defp deliver_http(outbound_integration, event_id, payload) do
    config = outbound_integration.transport_config
    json_payload = Jason.encode!(payload)

    headers =
      [
        {"content-type", "application/json"},
        {"x-event-id", event_id}
      ] ++ auth_headers(config.auth)

    case Req.post(config.url,
           body: json_payload,
           headers: headers,
           receive_timeout: config.timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, status, body_to_string(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, status, body_to_string(body)}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, inspect(reason)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp auth_headers(%Ash.Union{type: :bearer_token, value: auth}) do
    {:ok, auth} = Ash.load(auth, [:token], domain: AshIntegration.domain())
    [{"authorization", "Bearer #{auth.token}"}]
  end

  defp auth_headers(%Ash.Union{type: :api_key, value: auth}) do
    {:ok, auth} = Ash.load(auth, [:value], domain: AshIntegration.domain())
    [{auth.header_name, auth.value}]
  end

  defp auth_headers(%Ash.Union{type: :basic_auth, value: auth}) do
    {:ok, auth} = Ash.load(auth, [:password], domain: AshIntegration.domain())
    encoded = Base.encode64("#{auth.username}:#{auth.password}")
    [{"authorization", "Basic #{encoded}"}]
  end

  defp auth_headers(%Ash.Union{type: :none}), do: []

  defp log_delivery(
         outbound_integration,
         event_id,
         resource,
         action,
         resource_id,
         payload,
         status,
         opts \\ []
       ) do
    AshIntegration.delivery_log_resource()
    |> Ash.Changeset.for_create(
      :create,
      %{
        outbound_integration_id: outbound_integration.id,
        event_id: event_id,
        resource: resource,
        action: action,
        schema_version: outbound_integration.schema_version,
        resource_id: resource_id,
        request_payload: payload,
        response_status: Keyword.get(opts, :response_status),
        response_body: Keyword.get(opts, :response_body),
        error_message: Keyword.get(opts, :error_message),
        duration_ms: Keyword.get(opts, :duration_ms),
        status: status
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("Failed to create delivery log: #{inspect(err)}")
    end
  end

  defp record_success(outbound_integration) do
    Ash.update(outbound_integration, %{}, action: :record_success, authorize?: false)
  end

  defp record_failure(outbound_integration) do
    case Ash.update(outbound_integration, %{}, action: :record_failure, authorize?: false) do
      {:ok, _updated} ->
        :ok

      {:error, err} ->
        Logger.error(
          "Failed to record failure for outbound integration #{outbound_integration.id}: #{inspect(err)}"
        )
    end
  end

  defp truncate(nil, _), do: nil
  defp truncate(str, max) when byte_size(str) > max, do: binary_part(str, 0, max)
  defp truncate(str, _), do: str

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body) when is_map(body), do: Jason.encode!(body)
  defp body_to_string(body), do: inspect(body)
end
