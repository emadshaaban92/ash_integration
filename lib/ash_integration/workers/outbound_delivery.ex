defmodule AshIntegration.Workers.OutboundDelivery do
  @max_attempts 20

  use Oban.Worker,
    queue: :integration_delivery,
    max_attempts: @max_attempts,
    unique: [keys: [:event_id, :outbound_integration_id]]

  require Logger

  alias AshIntegration.LuaSandbox

  # Snoozing increments both `attempt` and `max_attempts`, which inflates
  # the backoff calculation on real failures. This corrects for that by
  # computing the actual number of real attempts (excluding snoozes).
  # See: https://hexdocs.pm/oban/Oban.Worker.html#module-snoozing-jobs
  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    corrected_attempt = @max_attempts - (job.max_attempts - job.attempt)
    Oban.Worker.backoff(%{job | attempt: corrected_attempt})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{
          "event_id" => event_id,
          "resource" => resource,
          "action" => action,
          "outbound_integration_id" => outbound_integration_id,
          "resource_id" => resource_id,
          "occurred_at" => occurred_at,
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
          occurred_at,
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
         occurred_at,
         snapshot
       ) do
    case Ash.get(AshIntegration.outbound_integration_resource(), outbound_integration_id,
           authorize?: false
         ) do
      {:ok, outbound_integration} ->
        if outbound_integration.active do
          run_pipeline(
            outbound_integration,
            event_id,
            resource,
            action,
            resource_id,
            occurred_at,
            snapshot
          )
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

  defp run_pipeline(
         outbound_integration,
         event_id,
         resource,
         action,
         resource_id,
         occurred_at,
         snapshot
       ) do
    event =
      AshIntegration.OutboundIntegrations.Info.build_event(%{
        id: event_id,
        resource: resource,
        action: action,
        schema_version: outbound_integration.schema_version,
        occurred_at: occurred_at,
        data: snapshot
      })

    case LuaSandbox.execute(outbound_integration.transform_script, event) do
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
    transport = AshIntegration.Transport.module_for(outbound_integration.transport_config.type)
    start_time = System.monotonic_time(:millisecond)
    result = transport.deliver(outbound_integration, event_id, resource_id, payload)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, metadata} ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload,
          :success,
          metadata_to_opts(metadata) ++ [duration_ms: duration_ms]
        )

        record_success(outbound_integration)
        :ok

      {:error, %{retryable: true} = metadata} ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload,
          :failed,
          metadata_to_opts(metadata) ++ [duration_ms: duration_ms]
        )

        record_failure(outbound_integration)
        {:error, "#{metadata.error_message} - retryable"}

      {:error, metadata} ->
        log_delivery(
          outbound_integration,
          event_id,
          resource,
          action,
          resource_id,
          payload,
          :failed,
          metadata_to_opts(metadata) ++ [duration_ms: duration_ms]
        )

        record_failure(outbound_integration)
        :ok
    end
  end

  @metadata_log_keys [
    :response_status,
    :response_body,
    :error_message,
    :kafka_offset,
    :kafka_partition
  ]

  defp metadata_to_opts(metadata) do
    metadata
    |> Map.take(@metadata_log_keys)
    |> Map.to_list()
    |> Enum.map(fn {k, v} -> {k, truncate_if_string(v)} end)
  end

  defp truncate_if_string(v) when is_binary(v), do: truncate(v, 102_400)
  defp truncate_if_string(v), do: v

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
        kafka_offset: Keyword.get(opts, :kafka_offset),
        kafka_partition: Keyword.get(opts, :kafka_partition),
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

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max)
    else
      str
    end
  end
end
