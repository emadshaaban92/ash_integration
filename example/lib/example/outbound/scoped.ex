defmodule Example.Outbound.Scoped do
  @moduledoc """
  Producer for `widget.scoped` — exercises every `project/3` decision branch (§5).
  The widget's `name` encodes the mode the test wants: `"deliver"` → public deliver,
  `"skip"` → `{:skip, _}` (no delivery), `"omit"` → the id is left out of the result
  (fail-closed → treated as skip), `"raise"` → `project` raises (deliveries park),
  `"bad_projection"` → `{:deliver, <non-map>}` (a botched redaction — must park, not
  ship full data), `"bad_decision"` → an unrecognized decision shape (must park, not
  crash). `data` is read with string keys because at dispatch it's reloaded from the DB.
  """
  use AshIntegration.Outbound.Declare.Producer

  @impl true
  def produce(_version, changesets_and_records, _context) do
    Map.new(changesets_and_records, fn {_cs, w} -> {w.id, %{id: w.id, mode: w.name}} end)
  end

  @impl true
  def example(_version), do: %{id: "widget-id", mode: "deliver"}

  @impl true
  def event_key(_version, %{id: id}), do: id
  def event_key(_version, %{"id" => id}), do: id

  @impl true
  def project(events, _subscriptions, _context) do
    cond do
      Enum.any?(events, &(mode(&1) == "raise")) ->
        raise("boom in project")

      # An entirely non-map return (contract is `%{event_id => decision}`) — a
      # producer bug that must fail-closed to park-all, not crash the processor with
      # a BadMapError on the caller's `Map.get`.
      Enum.any?(events, &(mode(&1) == "non_map")) ->
        :not_a_map

      true ->
        project_decisions(events)
    end
  end

  defp project_decisions(events) do
    for event <- events, mode(event) != "omit", into: %{} do
      case mode(event) do
        "skip" -> {event.id, {:skip, "test skip"}}
        # A non-map projection — the redaction boundary must park, not ship `data`.
        "bad_projection" -> {event.id, {:deliver, "not-a-map"}}
        # An entirely unrecognized decision — must park, not crash the job.
        "bad_decision" -> {event.id, :totally_bogus}
        _ -> {event.id, :deliver}
      end
    end
  end

  defp mode(event), do: event.data["mode"] || event.data[:mode]
end
