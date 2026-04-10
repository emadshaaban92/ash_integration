defmodule Example.SampleBuilderIntegrationTest do
  use Example.DataCase, async: false

  import Example.IntegrationHelpers

  alias AshIntegration.OutboundIntegrations.SampleBuilder

  describe "build_sample_event_data/4" do
    test "returns sample event data for a valid resource/version/action" do
      user = create_user!()

      assert {:ok, data} =
               SampleBuilder.build_sample_event_data("product", 1, "create", user)

      assert is_map(data)
      assert Map.has_key?(data, :id)
      assert Map.has_key?(data, :name)
      assert Map.has_key?(data, :sku)
    end

    test "returns error for unknown resource" do
      user = create_user!()

      assert {:error, :no_sample_data} =
               SampleBuilder.build_sample_event_data("nonexistent", 1, "create", user)
    end

    test "sample data has the same keys as real event data" do
      user = create_user!()
      product = create_product!()

      {:ok, real_data} =
        AshIntegration.EventDataLoader.load_event_data(
          "product",
          product.id,
          "create",
          1,
          user
        )

      {:ok, sample_data} =
        SampleBuilder.build_sample_event_data("product", 1, "create", user)

      assert Map.keys(real_data) |> Enum.sort() ==
               Map.keys(sample_data) |> Enum.sort()
    end

    test "uses real record when available, falls back to synthetic when not" do
      user = create_user!()

      # Delete all products so the loader falls back to synthetic
      Example.Catalog.Product
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, action: :destroy, authorize?: false))

      {:ok, synthetic_data} =
        SampleBuilder.build_sample_event_data("product", 1, "create", user)

      assert synthetic_data.id == "00000000-0000-0000-0000-000000000000"
      assert synthetic_data.name == "Example Product"

      # Create a real product — should now use real data
      product = create_product!()

      {:ok, real_data} =
        SampleBuilder.build_sample_event_data("product", 1, "create", user)

      assert real_data.id == product.id
    end
  end
end
