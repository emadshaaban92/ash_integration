defmodule Example.Outbound.HostTimestampsTest do
  @moduledoc """
  Pins the creation-timestamp attribute every AshIntegration extension injects.

  The transformers add `create_timestamp :inserted_at` (and, except on the
  append-only `Log`, `update_timestamp :updated_at`) — Ash's own `timestamps()`
  names — each only if the host hasn't declared an attribute of that name.

  The load-bearing case is a host resource that calls `timestamps()` itself: it
  already has its creation timestamp, so the extension must not add a second one
  under another name (the bug a `created_at` default had — such a host ended up
  with both `inserted_at` and `created_at`). The host resources live in
  `test/support/host_timestamp_resources.ex`.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo

  alias Example.Test.HostTimestamps.{
    HostConnection,
    HostEvent,
    HostEventDelivery,
    HostLog,
    HostSubscription
  }

  @host_resources [HostConnection, HostSubscription, HostEvent, HostEventDelivery, HostLog]

  @stock_resources [
    Example.Outbound.Connection,
    Example.Outbound.Subscription,
    Example.Outbound.Event,
    Example.Outbound.EventDelivery,
    Example.Outbound.Log
  ]

  for resource <- @host_resources do
    @resource resource

    test "#{inspect(resource)} (calls timestamps()) gets no second creation timestamp" do
      assert creation_timestamp_names(@resource) == [:inserted_at]
      refute ResourceInfo.attribute(@resource, :created_at)
      assert ResourceInfo.attribute(@resource, :updated_at)
    end
  end

  for resource <- @stock_resources do
    @resource resource

    test "#{inspect(resource)} gets the injected inserted_at creation timestamp" do
      assert creation_timestamp_names(@resource) == [:inserted_at]
      refute ResourceInfo.attribute(@resource, :created_at)
    end
  end

  # A creation timestamp as `create_timestamp` builds it: defaulted to now on
  # create, never touched on update. (`update_timestamp` sets `update_default`.)
  defp creation_timestamp_names(resource) do
    resource
    |> ResourceInfo.attributes()
    |> Enum.filter(&creation_timestamp?/1)
    |> Enum.map(& &1.name)
  end

  defp creation_timestamp?(attribute) do
    attribute.default == (&DateTime.utc_now/0) and is_nil(attribute.update_default)
  end
end
