defmodule Example.Repo.Migrations.RenameDeliveryLogsToOutboundIntegrationLogs do
  use Ecto.Migration

  def up do
    rename table(:integration_delivery_logs), to: table(:outbound_integration_logs)
  end

  def down do
    rename table(:outbound_integration_logs), to: table(:integration_delivery_logs)
  end
end
