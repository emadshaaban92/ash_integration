defmodule Example.Outbound.BadKey do
  @moduledoc """
  Fixture producer whose `event_key/2` returns a NON-string term (a tuple) —
  exercises capture's fail-fast: a non-string key is a code bug and raises at
  capture rather than being coerced into a garbage lane key (§4.4). Wired to
  `test.bad_key` on `Example.Catalog.Widget`; inert unless something subscribes.
  """
  use AshIntegration.Outbound.Declare.Producer

  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_changeset, record} -> {record.id, %{id: record.id}} end)
  end

  @impl true
  def example(_version), do: %{id: "x"}

  # Deliberately wrong: a tuple is not a String.t() and must not be coerced.
  @impl true
  def event_key(_version, %{id: id}), do: {:widget, id}

  @impl true
  def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
end
