defmodule AshIntegration.Changes.DefaultSchemaVersion do
  use Ash.Resource.Change

  alias AshIntegration.OutboundIntegrations.Info

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :schema_version) do
      changeset
    else
      case Ash.Changeset.get_attribute(changeset, :resource) do
        nil ->
          changeset

        resource_identifier ->
          case Info.resource_module(resource_identifier) do
            nil ->
              changeset

            resource ->
              Ash.Changeset.force_change_attribute(
                changeset,
                :schema_version,
                Info.latest_version(resource)
              )
          end
      end
    end
  end
end
