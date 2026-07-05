defmodule Example.Catalog.Widget do
  @moduledoc """
  Event-first source resource (carries `AshIntegration.Outbound.Declare.Source`).

  A single `:update` contributes to TWO event types via one producer keyed on the
  widget id, so both events share an event key under any connection — exercising
  the fan-out + shared-key behaviour (serialize together, coalesce only within a
  subscription).
  """
  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Declare.Source],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "widgets"
    repo Example.Repo
  end

  outbound_events do
    # source_resource omitted — provenance derives from the resource's short_name (:widget).

    event "widget.updated" do
      actions [:create, :update]
      producer Example.Outbound.WidgetUpdated
      version 1
    end

    event "stock.changed" do
      actions [:update, :destroy]
      producer Example.Outbound.StockChanged
      version 1
    end

    # Fixture: every `project/3` decision branch, selected by the widget name
    # (see Example.Outbound.Scoped). Inert unless something subscribes.
    event "widget.scoped" do
      actions [:create, :update]
      producer Example.Outbound.Scoped
      version 1
    end

    # Fixture: a deliberately-broken producer (blank event_key) so capture's
    # blank-key fallback is exercised end-to-end. Inert unless something actually
    # subscribes to `test.blank_key`.
    event "test.blank_key" do
      actions [:create]
      producer Example.Outbound.BlankKey
      version 1
    end

    # Fixture: a producer whose event_key/2 returns a non-string term, so capture's
    # fail-fast (raise on a non-string key) is exercised. Inert unless subscribed.
    event "test.bad_key" do
      actions [:create]
      producer Example.Outbound.BadKey
      version 1
    end

    # Fixture: a producer that reports its project/3 batch sizes (via ProjectProbe)
    # so a test can prove dispatch batches project per (type, version). Inert
    # unless something subscribes to `test.batched`.
    event "test.batched" do
      actions [:create]
      producer Example.Outbound.Batched
      version 1
    end

    # Fixture pair: a producer that fails via throw/exit (not a raise). The isolated
    # variant opts into `capture_isolation?` so the failure is caught and the host
    # action still commits; the coupled variant leaves isolation off so the same
    # throw/exit rolls the host transaction back. Both inert unless subscribed.
    event "test.isolated_erratic" do
      actions [:create]
      producer Example.Outbound.Erratic
      version 1
      capture_isolation?(true)
    end

    event "test.coupled_erratic" do
      actions [:create]
      producer Example.Outbound.Erratic
      version 1
    end
  end

  actions do
    default_accept [:name, :stock]
    defaults [:read, create: :*]

    update :update do
      accept [:name, :stock]
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
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :stock, :integer, allow_nil?: false, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
