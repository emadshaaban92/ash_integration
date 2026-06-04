defmodule AshIntegration.Outbound.SourceDslTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Declare.Source.Info

  defmodule ProductProducer do
    @moduledoc false
    use AshIntegration.Outbound.Declare.Producer

    @impl true
    def produce(_version, pairs, _context),
      do: Map.new(pairs, fn {_changeset, record} -> {record.id, %{id: record.id}} end)

    @impl true
    def example(_version), do: %{id: "p1"}

    @impl true
    def event_key(_version, %{id: id}), do: id

    @impl true
    def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshIntegration.Outbound.SourceDslTest.Product
      resource AshIntegration.Outbound.SourceDslTest.DerivedProduct
    end
  end

  defmodule Product do
    @moduledoc false
    use Ash.Resource,
      domain: AshIntegration.Outbound.SourceDslTest.Domain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshIntegration.Outbound.Declare.Source]

    outbound_events do
      source_resource "product"

      event "product.created" do
        actions([:create])
        producer(AshIntegration.Outbound.SourceDslTest.ProductProducer)
        version(1)
      end

      # Declared with an ATOM type to prove atom→string normalization.
      event :"stock.changed" do
        actions([:update, :destroy])
        producer(AshIntegration.Outbound.SourceDslTest.ProductProducer)
        version(1)
        version(2)
      end
    end

    attributes do
      uuid_v7_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end
  end

  defmodule DerivedProduct do
    @moduledoc false
    use Ash.Resource,
      domain: AshIntegration.Outbound.SourceDslTest.Domain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshIntegration.Outbound.Declare.Source]

    # No `source_resource` — provenance derives from the short_name (:derived_product).
    outbound_events do
      event "product.created" do
        actions([:create])
        producer(AshIntegration.Outbound.SourceDslTest.ProductProducer)
        version(1)
      end
    end

    attributes do
      uuid_v7_primary_key :id
    end

    actions do
      defaults [:create, :read]
    end
  end

  test "source_resource is read from the section when declared (override)" do
    assert Info.source_resource(Product) == "product"
  end

  test "source_resource defaults to the resource short_name when not declared" do
    # DerivedProduct omits `source_resource`, so provenance derives from its
    # short_name (:derived_product) — no hand-authored identifier required.
    assert Info.source_resource(DerivedProduct) == "derived_product"
  end

  test "event types are normalized to canonical strings (string or atom inputs)" do
    assert Info.event_types(Product) == ["product.created", "stock.changed"]
  end

  test "actions and producer are read per event" do
    created = Info.event(Product, "product.created")
    assert Info.actions(created) == [:create]
    assert Info.producer(created) == ProductProducer

    stock = Info.event(Product, "stock.changed")
    assert Info.actions(stock) == [:update, :destroy]
  end

  test "versions are read per event, sorted ascending" do
    created = Info.event(Product, "product.created")
    assert Info.versions(created) == [1]

    stock = Info.event(Product, "stock.changed")
    assert Info.versions(stock) == [1, 2]
  end

  test "source?/1 distinguishes extension-carrying resources" do
    assert Info.source?(Product)
    refute Info.source?(AshIntegration.Test.Parent)
  end

  test "the verifier rejects an event listing an action that doesn't exist on the resource" do
    # Ash runs DSL verifiers in the parallel-checker phase, so the rejection
    # surfaces as a compiler diagnostic (a hard error at `mix compile`); capture
    # it rather than rely on a synchronous raise from Code.compile_string/1.
    bad = """
    defmodule AshIntegration.Outbound.SourceDslTest.BadProduct do
      use Ash.Resource,
        domain: AshIntegration.Outbound.SourceDslTest.Domain,
        data_layer: Ash.DataLayer.Simple,
        extensions: [AshIntegration.Outbound.Declare.Source]

      outbound_events do

        event "product.created" do
          actions [:create, :nope]
          producer AshIntegration.Outbound.SourceDslTest.ProductProducer
          version 1
        end
      end

      attributes do
        uuid_v7_primary_key :id
      end

      actions do
        defaults [:create, :read]
      end
    end
    """

    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(bad)
        rescue
          _ -> :error
        end
      end)

    messages = Enum.map(diagnostics, & &1.message)

    assert Enum.any?(messages, &(&1 =~ "do not exist" and &1 =~ ":nope")),
           "expected a verifier diagnostic naming the missing :nope action, got: #{inspect(messages)}"
  end

  test "the verifier rejects an event that declares no version" do
    # A versionless event would compile cleanly but be permanently un-subscribable
    # (empty version set in the catalog). The verifier must reject it at compile.
    bad = """
    defmodule AshIntegration.Outbound.SourceDslTest.VersionlessProduct do
      use Ash.Resource,
        domain: AshIntegration.Outbound.SourceDslTest.Domain,
        data_layer: Ash.DataLayer.Simple,
        extensions: [AshIntegration.Outbound.Declare.Source]

      outbound_events do

        event "product.created" do
          actions [:create]
          producer AshIntegration.Outbound.SourceDslTest.ProductProducer
        end
      end

      attributes do
        uuid_v7_primary_key :id
      end

      actions do
        defaults [:create, :read]
      end
    end
    """

    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(bad)
        rescue
          _ -> :error
        end
      end)

    messages = Enum.map(diagnostics, & &1.message)

    assert Enum.any?(messages, &(&1 =~ "declares no `version`")),
           "expected a verifier diagnostic about the missing version, got: #{inspect(messages)}"
  end
end
