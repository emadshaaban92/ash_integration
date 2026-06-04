defmodule Example.Outbound.Batched do
  @moduledoc """
  Producer for `test.batched` — a fixture that reports, via
  `Example.Outbound.ProjectProbe`, how many events each `project/3` call received.
  Used to prove the relay runs `project` once per (event_type, version) batch
  (open #2). Inert unless something subscribes to `test.batched`.
  """
  use AshIntegration.Outbound.Declare.Producer

  alias Example.Outbound.ProjectProbe

  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_cs, record} -> {record.id, %{id: record.id}} end)
  end

  @impl true
  def example(_version), do: %{id: "widget-id"}

  @impl true
  def event_key(_version, %{id: id}), do: id
  def event_key(_version, %{"id" => id}), do: id

  @impl true
  def project(events, _subscriptions, _context) do
    if ProjectProbe.running?(), do: ProjectProbe.record(length(events))
    Map.new(events, &{&1.id, :deliver})
  end
end
