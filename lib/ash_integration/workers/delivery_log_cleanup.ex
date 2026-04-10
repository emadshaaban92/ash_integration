defmodule AshIntegration.Workers.DeliveryLogCleanup do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Ash.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = AshIntegration.delivery_log_retention_days()

    cleanup_old_delivery_logs(retention_days)
    cleanup_old_events(retention_days)

    :ok
  end

  defp cleanup_old_delivery_logs(days) do
    delivery_log_resource = AshIntegration.delivery_log_resource()

    delivery_log_resource
    |> Ash.Query.for_read(:older_than, %{days: days})
    |> Ash.bulk_destroy!(:destroy, %{},
      strategy: :atomic_batches,
      stream_batch_size: 500,
      authorize?: false,
      return_errors?: false
    )
  end

  defp cleanup_old_events(days) do
    AshIntegration.outbound_integration_event_resource()
    |> Ash.Query.for_read(:older_than, %{days: days})
    |> Ash.bulk_destroy!(:destroy, %{},
      strategy: :atomic_batches,
      stream_batch_size: 500,
      authorize?: false,
      return_errors?: false
    )
  end
end
