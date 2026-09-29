# Host resources that call Ash's `timestamps()` themselves, one per
# AshIntegration extension, for `Example.Outbound.HostTimestampsTest`. Defined in
# test/support (compiled before protocol consolidation) rather than in the test
# file. Compile-time only: no table exists and their domain is not in the app's
# `ash_domains`, so codegen never sees them — the test reads their DSL, never the
# database.
defmodule Example.Test.HostTimestamps.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Example.Test.HostTimestamps.HostConnection
    resource Example.Test.HostTimestamps.HostSubscription
    resource Example.Test.HostTimestamps.HostEvent
    resource Example.Test.HostTimestamps.HostEventDelivery
    resource Example.Test.HostTimestamps.HostLog
  end
end

defmodule Example.Test.HostTimestamps.HostConnection do
  @moduledoc false
  use Ash.Resource,
    domain: Example.Test.HostTimestamps.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Connection]

  postgres do
    table "host_ts_connections"
    repo Example.Repo
  end

  attributes do
    timestamps()
  end
end

defmodule Example.Test.HostTimestamps.HostSubscription do
  @moduledoc false
  use Ash.Resource,
    domain: Example.Test.HostTimestamps.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.Subscription]

  postgres do
    table "host_ts_subscriptions"
    repo Example.Repo
  end

  attributes do
    timestamps()
  end
end

defmodule Example.Test.HostTimestamps.HostEvent do
  @moduledoc false
  use Ash.Resource,
    domain: Example.Test.HostTimestamps.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Capture.Event]

  postgres do
    table "host_ts_events"
    repo Example.Repo
  end

  attributes do
    timestamps()
  end
end

defmodule Example.Test.HostTimestamps.HostEventDelivery do
  @moduledoc false
  use Ash.Resource,
    domain: Example.Test.HostTimestamps.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.EventDelivery]

  postgres do
    table "host_ts_event_deliveries"
    repo Example.Repo
  end

  attributes do
    timestamps()
  end
end

defmodule Example.Test.HostTimestamps.HostLog do
  @moduledoc false
  use Ash.Resource,
    domain: Example.Test.HostTimestamps.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshIntegration.Outbound.Delivery.Log]

  postgres do
    table "host_ts_delivery_logs"
    repo Example.Repo
  end

  attributes do
    timestamps()
  end
end
