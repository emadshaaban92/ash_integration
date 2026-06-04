defmodule AshIntegration.Outbound.Wire.TransportDispatchTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Wire.Transport

  # `deliver/2` only reads `connection.transport_config`, so a bare struct-like map
  # is enough to exercise the transport-tag dispatch without a DB or a broker.
  defp connection(type), do: %{transport_config: %Ash.Union{type: type, value: %{}}}

  describe "module_for/1" do
    test "maps the supported transports" do
      assert Transport.module_for(:http) == AshIntegration.Outbound.Wire.Transports.Http
      assert Transport.module_for(:kafka) == AshIntegration.Outbound.Wire.Transports.Kafka
    end
  end

  describe "deliver/2 with an unsupported transport" do
    test "a legacy :grpc row is rejected with a friendly, non-retryable error" do
      assert {:error, error} = Transport.deliver(connection(:grpc), %{id: "e1"})
      assert error.failure_class == :transport
      assert error.retryable == false
      assert error.error_message =~ "gRPC transport was removed"
      assert error.error_message =~ "migrate it to :http or :kafka"
    end

    test "an unknown transport tag is rejected without crashing" do
      assert {:error, error} = Transport.deliver(connection(:carrier_pigeon), %{id: "e1"})
      assert error.failure_class == :transport
      assert error.error_message =~ "Unsupported transport"
    end
  end

  describe "deliver_batch/2 with an unsupported transport" do
    test "every row gets the classified error (no FunctionClauseError)" do
      events = [%{id: "e1"}, %{id: "e2"}]
      results = Transport.deliver_batch(connection(:grpc), events)

      assert {:error, %{failure_class: :transport}} = results["e1"]
      assert {:error, %{failure_class: :transport}} = results["e2"]
    end
  end

  describe "HTTP transport with an unloaded subscription" do
    test "returns a classified error instead of crashing on Ash.NotLoaded" do
      event = %{subscription: %Ash.NotLoaded{type: :relationship, field: :subscription}}

      assert {:error, error} =
               AshIntegration.Outbound.Wire.Transports.Http.deliver(connection(:http), event)

      assert error.failure_class == :transport
      assert error.retryable == false
      assert error.error_message =~ "subscription was not loaded"
    end
  end
end
