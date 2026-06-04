defmodule Example.Outbound.Subscription do
  use Ash.Resource,
    domain: Example.Integration,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.Subscription],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "outbound_subscriptions"
    repo Example.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  aggregates do
    # Most recent delivery for this subscription, used by the subscriptions list.
    # Computed in the list query (no per-row N+1).
    max :last_delivered_at, :events, :updated_at do
      filter expr(state == :delivered)
    end
  end
end
