defmodule AshIntegration.Outbound.Delivery.Route.KafkaRoute do
  @moduledoc """
  The per-subscription Kafka route. The connection owns the brokers, security,
  acks, and a default topic; this optionally overrides the topic for *this* event
  type. A nil topic falls back to the connection's default.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :topic, :string, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
