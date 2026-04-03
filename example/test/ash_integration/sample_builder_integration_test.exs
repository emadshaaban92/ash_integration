defmodule Example.SampleBuilderIntegrationTest do
  use Example.DataCase, async: true

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

      assert {:error, :unable_to_build_sample} =
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
  end
end
