defmodule AshIntegration.Outbound.RegistryTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Declare.Registry

  defmodule Producer do
    @moduledoc false
    use AshIntegration.Outbound.Declare.Producer

    @impl true
    def produce(_version, pairs, _context),
      do: Map.new(pairs, fn {_changeset, record} -> {record.id, %{id: record.id}} end)

    @impl true
    def example(_version), do: %{}

    @impl true
    def event_key(_version, %{id: id}), do: id

    @impl true
    def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
  end

  defmodule OtherProducer do
    @moduledoc false
    use AshIntegration.Outbound.Declare.Producer

    @impl true
    def produce(_version, pairs, _context),
      do: Map.new(pairs, fn {_changeset, record} -> {record.id, %{id: record.id}} end)

    @impl true
    def example(_version), do: %{}

    @impl true
    def event_key(_version, %{id: id}), do: id

    @impl true
    def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshIntegration.Outbound.RegistryTest.Product
      resource AshIntegration.Outbound.RegistryTest.Item
      resource AshIntegration.Outbound.RegistryTest.ConflictItem
    end
  end

  defmodule Product do
    @moduledoc false
    use Ash.Resource,
      domain: AshIntegration.Outbound.RegistryTest.Domain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshIntegration.Outbound.Declare.Source]

    outbound_events do
      source_resource "product"

      event "product.created" do
        actions([:create])
        producer(AshIntegration.Outbound.RegistryTest.Producer)
        version(1)
      end

      event "stock.changed" do
        actions([:update])
        producer(AshIntegration.Outbound.RegistryTest.Producer)
        version(1)
      end
    end

    attributes do
      uuid_v7_primary_key :id
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end
  end

  defmodule Item do
    @moduledoc false
    use Ash.Resource,
      domain: AshIntegration.Outbound.RegistryTest.Domain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshIntegration.Outbound.Declare.Source]

    outbound_events do
      source_resource "item"

      # Same event type + same producer as Product → consistent union, two versions.
      event "stock.changed" do
        actions([:create, :update])
        producer(AshIntegration.Outbound.RegistryTest.Producer)
        version(1)
        version(2)
      end
    end

    attributes do
      uuid_v7_primary_key :id
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end
  end

  defmodule ConflictItem do
    @moduledoc false
    use Ash.Resource,
      domain: AshIntegration.Outbound.RegistryTest.Domain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshIntegration.Outbound.Declare.Source]

    outbound_events do
      source_resource "conflict_item"

      # Same event type but a DIFFERENT producer module → must be rejected.
      event "stock.changed" do
        actions([:create])
        producer(AshIntegration.Outbound.RegistryTest.OtherProducer)
        version(1)
      end
    end

    attributes do
      uuid_v7_primary_key :id
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end
  end

  test "triggers maps (resource, action) to the events it contributes" do
    triggers = Registry.triggers([Product, Item])

    assert [%{event_type: "product.created", producer: Producer}] = triggers[{Product, :create}]
    assert [%{event_type: "stock.changed"}] = triggers[{Product, :update}]
    assert [%{event_type: "stock.changed"}] = triggers[{Item, :create}]
    assert [%{event_type: "stock.changed"}] = triggers[{Item, :update}]
  end

  test "catalog unions versions + producers across resources for a shared event type" do
    catalog = Registry.catalog([Product, Item])

    assert catalog["product.created"].versions == [1]

    stock = catalog["stock.changed"]
    assert stock.versions == [1, 2]
    assert {Product, :update} in stock.producers
    assert {Item, :create} in stock.producers
    assert {Item, :update} in stock.producers
  end

  test "consistent producers verify cleanly" do
    assert Registry.verify!([Product, Item]) == :ok
  end

  test "verify! raises when resources name different producers for one event type" do
    assert_raise RuntimeError, ~r/Conflicting producers/, fn ->
      Registry.verify!([Product, ConflictItem])
    end
  end
end
