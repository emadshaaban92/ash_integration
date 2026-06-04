defmodule Example.Outbound.ProducerTest do
  @moduledoc """
  Producer-contract unit tests (§4.4). The load-bearing one is the **value-stable
  `event_key`** invariant: a given entity must yield the SAME key across versions
  (and across the resources that produce a shared event type), because the
  ordering/coalescing lane is `(connection, event_key)`. Getting this wrong keys
  siblings onto the same lane and silently coalesces them away — the one place
  the framework can't check, so we pin it here.
  """
  use ExUnit.Case, async: true

  alias Example.Outbound.{StockChanged, WidgetUpdated}

  test "WidgetUpdated.event_key is value-stable across versions for the same entity" do
    v1 = %{id: "widget-123", name: "x", stock: 1}
    # A hypothetical v2 payload — different shape, same entity.
    v2 = %{id: "widget-123", name: "x", stock: 1, color: "red"}

    assert WidgetUpdated.event_key(1, v1) == WidgetUpdated.event_key(2, v2)
    assert WidgetUpdated.event_key(1, v1) == "widget-123"
  end

  test "StockChanged keys on the parent widget regardless of version or producing record" do
    # Widget-shaped payload and item-shaped payload for the SAME widget …
    widget_payload = %{widget_id: "w-1", stock: 9}
    item_payload = %{widget_id: "w-1", quantity: 3}

    # … must land on one lane (the widget), across versions and record types.
    assert StockChanged.event_key(1, widget_payload) == "w-1"
    assert StockChanged.event_key(2, item_payload) == "w-1"
    assert StockChanged.event_key(1, widget_payload) == StockChanged.event_key(2, item_payload)
  end

  test "example/1 mirrors produce's payload shape (drives the transform preview)" do
    assert %{id: _, name: _, stock: _} = WidgetUpdated.example(1)
    assert %{widget_id: _} = StockChanged.example(1)
  end
end
