defmodule Example.Catalog.StockItem do
  @moduledoc """
  Second event-first source for `stock.changed` (carries
  `AshIntegration.Outbound.Declare.Source`).

  A stock item belongs to a widget. A change to ONE item contributes a
  `stock.changed` event keyed on the **parent widget id** (not the item id), via
  a loader whose `event_key/1` returns `widget_id`. This is the cross-resource
  case from §3.5/§5.2: `Widget` and `StockItem` both produce the same
  `stock.changed` schema, but an item change keys on the widget it belongs to —
  so item and widget changes for the same widget land on ONE ordering lane and
  coalesce together. Mis-keying here would silently drop sibling snapshots
  (§5.3), which is exactly what the dispatch tests guard.
  """
  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Declare.Source],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stock_items"
    repo Example.Repo
  end

  outbound_events do
    # source_resource omitted — provenance derives from short_name (:stock_item).

    event "stock.changed" do
      actions [:create, :update]
      producer Example.Outbound.StockChanged
      version 1
    end
  end

  actions do
    default_accept [:widget_id, :quantity]
    defaults [:read, create: :*]

    update :update do
      accept [:widget_id, :quantity]
      require_atomic? false
    end

    destroy :destroy do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :widget_id, :uuid, allow_nil?: false, public?: true
    attribute :quantity, :integer, allow_nil?: false, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
