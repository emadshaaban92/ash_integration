defmodule AshIntegration.TransformPreviewTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Web.OutboundIntegrationLive.Helpers

  @sample_event %{
    "id" => "event-123",
    "resource" => "product",
    "action" => "create",
    "data" => %{"name" => "Widget", "sku" => "W-001"}
  }

  describe "transform_preview/3 nil/empty inputs" do
    test "returns nil when script is nil" do
      assert Helpers.transform_preview(nil, @sample_event, nil) == nil
    end

    test "returns nil when sample event is nil" do
      assert Helpers.transform_preview("result = event", nil, nil) == nil
    end

    test "returns nil when script is empty string" do
      assert Helpers.transform_preview("", @sample_event, nil) == nil
    end
  end

  describe "transform_preview/3 passthrough script" do
    test "returns JSON-encoded result for identity transform" do
      script = "result = event"

      assert {:ok, json} = Helpers.transform_preview(script, @sample_event, nil)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["id"] == "event-123"
      assert decoded["data"]["name"] == "Widget"
    end
  end

  describe "transform_preview/3 transforming script" do
    test "returns transformed payload as JSON" do
      script = ~S"""
      result = {
        product_name = event.data.name,
        product_sku = event.data.sku
      }
      """

      assert {:ok, json} = Helpers.transform_preview(script, @sample_event, nil)

      decoded = Jason.decode!(json)
      assert decoded["product_name"] == "Widget"
      assert decoded["product_sku"] == "W-001"
    end
  end

  describe "transform_preview/3 skip" do
    test "returns :skip when script does not set result" do
      script = "local x = 1 + 1"
      assert {:ok, :skip} = Helpers.transform_preview(script, @sample_event, nil)
    end
  end

  describe "transform_preview/3 errors" do
    test "returns error tuple for Lua syntax errors" do
      script = "result = {"
      assert {:error, message} = Helpers.transform_preview(script, @sample_event, nil)
      assert is_binary(message)
    end

    test "returns error tuple for Lua runtime errors" do
      script = ~S'error("boom")'
      assert {:error, message} = Helpers.transform_preview(script, @sample_event, nil)
      assert message =~ "boom"
    end
  end

  describe "transform_preview/3 without grpc config" do
    test "returns two-element ok tuple when grpc_config is nil" do
      script = "result = event"
      assert {:ok, _json} = Helpers.transform_preview(script, @sample_event, nil)
    end

    test "returns two-element ok tuple when grpc_config has no proto" do
      script = "result = event"
      grpc_config = %{proto_definition: "", service: "", method: ""}
      assert {:ok, _json} = Helpers.transform_preview(script, @sample_event, grpc_config)
    end

    test "returns two-element ok tuple when grpc_config has partial fields" do
      script = "result = event"
      grpc_config = %{proto_definition: "syntax = \"proto3\";", service: "Foo", method: ""}
      assert {:ok, _json} = Helpers.transform_preview(script, @sample_event, grpc_config)
    end
  end
end
