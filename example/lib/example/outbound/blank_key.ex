defmodule Example.Outbound.BlankKey do
  @moduledoc """
  Fixture producer whose `event_key/2` returns `nil` — exercises capture's
  fail-fast: the callback is mandatory and must return a non-empty string, so a
  nil key raises rather than being papered over (§4.4). Wired to `test.blank_key`
  on `Example.Catalog.Widget`; inert unless something subscribes.
  """
  use AshIntegration.Outbound.Declare.Producer

  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_changeset, record} -> {record.id, %{id: record.id}} end)
  end

  @impl true
  def example(_version), do: %{id: "x"}

  @impl true
  def event_key(_version, _payload), do: nil

  @impl true
  def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
end
