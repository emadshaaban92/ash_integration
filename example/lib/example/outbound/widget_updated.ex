defmodule Example.Outbound.WidgetUpdated do
  @moduledoc """
  Producer for `widget.updated` (Widget records). Captures from the in-memory
  record under system authority (§4.2) — no per-actor read — and ships to everyone
  subscribed (the public one-liner `project`, matching Widget's always-allow policy).
  """
  use AshIntegration.Outbound.Declare.Producer

  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_changeset, widget} ->
      {widget.id, %{id: widget.id, name: widget.name, stock: widget.stock}}
    end)
  end

  @impl true
  def example(_version), do: %{id: "widget-id", name: "Sample Widget", stock: 42}

  @impl true
  def event_key(_version, %{id: id}), do: id
  def event_key(_version, %{"id" => id}), do: id

  @impl true
  def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
end
