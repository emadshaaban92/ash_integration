defmodule AshIntegration.Workers.DeliveryLogCleanup do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Ash.Query

  @batch_size 1_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    delivery_log_resource = AshIntegration.delivery_log_resource()
    retention_days = AshIntegration.delivery_log_retention_days()

    delivery_log_resource
    |> Ash.Query.for_read(:older_than, %{days: retention_days})
    |> Ash.Query.limit(@batch_size)
    |> Ash.bulk_destroy!(:destroy, %{},
      strategy: [:atomic, :stream, :atomic_batches],
      authorize?: false,
      return_errors?: false
    )

    :ok
  end
end
