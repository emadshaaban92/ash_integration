defmodule AshIntegration.Outbound.Delivery.ResolverTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Delivery.Resolver

  @created_at ~U[2026-07-05 00:00:00Z]

  defp envelope do
    %{
      id: "evt_1",
      type: "order.shipped",
      version: "1",
      event_key: "order-42",
      data: %{"order" => 42}
    }
  end

  defp connection(transport, config) do
    %{transport_config: %Ash.Union{type: transport, value: config}}
  end

  # A no-op-ish subscription: a transform that just adds the html/text bodies email
  # requires and otherwise returns the pre-seeded defaults untouched, so the stored
  # descriptor's headers are exactly what `preseed` produced.
  defp subscription(transport, route, transform_source) do
    %{
      route_config: %Ash.Union{type: transport, value: route},
      transform_source: transform_source,
      transform_runtime: :lua
    }
  end

  describe "email preseed omits content-type (MIME owns Content-Type)" do
    test "the resolved email descriptor headers carry wire metadata but no content-type" do
      config = %{from: "bot@acme.com", headers: %{}}
      route = %{to: ["a@x.com"], cc: nil, subject: "Order shipped"}

      # Return the pre-seeded defaults verbatim, only adding the required bodies.
      transform = ~S"""
      function transform(event, defaults)
        defaults.html = "<b>shipped</b>"
        defaults.text = "shipped"
        return defaults
      end
      """

      assert {:ok, descriptor, _hash} =
               Resolver.resolve(
                 connection(:email, config),
                 subscription(:email, route, transform),
                 envelope(),
                 @created_at
               )

      headers = descriptor["headers"]

      # No content-type was seeded for email (case-insensitive check).
      refute Enum.any?(Map.keys(headers), &(String.downcase(&1) == "content-type"))

      # The x--prefixed wire metadata still seeds.
      assert headers["x-event-id"] == "evt_1"
      assert headers["x-event-type"] == "order.shipped"
      assert headers["x-event-version"] == "1"
    end

    test "a connection-static header still seeds for email" do
      config = %{from: "bot@acme.com", headers: %{"x-team" => "billing"}}
      route = %{to: ["a@x.com"], cc: nil, subject: "Hi"}

      transform = ~S"""
      function transform(event, defaults)
        defaults.text = "hi"
        return defaults
      end
      """

      assert {:ok, descriptor, _hash} =
               Resolver.resolve(
                 connection(:email, config),
                 subscription(:email, route, transform),
                 envelope(),
                 @created_at
               )

      assert descriptor["headers"]["x-team"] == "billing"
      refute Enum.any?(Map.keys(descriptor["headers"]), &(String.downcase(&1) == "content-type"))
    end
  end

  describe "HTTP/Kafka preseed still seed the default JSON content-type" do
    test "http keeps content-type: application/json" do
      # A literal public IP keeps the egress check hermetic (no DNS lookup).
      config = %{base_url: "https://1.1.1.1", headers: %{}}
      route = %{path: "/hook", method: :post}

      assert {:ok, descriptor, _hash} =
               Resolver.resolve(
                 connection(:http, config),
                 subscription(:http, route, ""),
                 envelope(),
                 @created_at
               )

      assert descriptor["headers"]["content-type"] == "application/json"
      assert descriptor["headers"]["x-event-id"] == "evt_1"
    end

    test "kafka keeps content-type: application/json" do
      config = %{topic: "events", headers: %{}}
      route = %{topic: "events"}

      assert {:ok, descriptor, _hash} =
               Resolver.resolve(
                 connection(:kafka, config),
                 subscription(:kafka, route, ""),
                 envelope(),
                 @created_at
               )

      assert descriptor["headers"]["content-type"] == "application/json"
      # Kafka renders wire metadata un-prefixed.
      assert descriptor["headers"]["event-id"] == "evt_1"
    end
  end
end
