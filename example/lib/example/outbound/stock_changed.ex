defmodule Example.Outbound.StockChanged do
  @moduledoc """
  Producer for `stock.changed`, produced by BOTH `Widget` and `StockItem` (§3.5).
  One producer per event type (§4.4): it pattern-matches the in-memory record to
  build the payload, and both resources **key on the parent widget id** — so a
  widget change and one of its stock-item changes land on ONE ordering lane and
  coalesce together. Mis-keying here would silently drop sibling snapshots (§5.3).
  """
  use AshIntegration.Outbound.Declare.Producer

  alias Example.Catalog.{StockItem, Widget}

  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_changeset, record} ->
      {record.id, payload(record)}
    end)
  end

  defp payload(%Widget{} = widget), do: %{widget_id: widget.id, stock: widget.stock}
  defp payload(%StockItem{} = item), do: %{widget_id: item.widget_id, quantity: item.quantity}

  @impl true
  def example(_version), do: %{widget_id: "widget-id", stock: 10}

  # Value-stable per entity across record types: both resources key on the widget
  # the payload snapshots (§4.4).
  @impl true
  def event_key(_version, %{widget_id: widget_id}), do: widget_id
  def event_key(_version, %{"widget_id" => widget_id}), do: widget_id

  @impl true
  def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
end
