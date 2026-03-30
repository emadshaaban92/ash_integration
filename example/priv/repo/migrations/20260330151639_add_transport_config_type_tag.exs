defmodule Example.Repo.Migrations.AddTransportConfigTypeTag do
  use Ecto.Migration

  def up do
    execute """
    UPDATE outbound_integrations
    SET transport_config = jsonb_set(transport_config, '{type}', '"http"')
    WHERE transport = 'http'
    AND transport_config IS NOT NULL
    AND NOT (transport_config ? 'type')
    """
  end

  def down do
    execute """
    UPDATE outbound_integrations
    SET transport_config = transport_config - 'type'
    WHERE transport_config ? 'type'
    """
  end
end
