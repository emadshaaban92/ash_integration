defmodule Example.Outbound.Erratic do
  @moduledoc """
  Fixture producer whose `produce/3` fails via a NON-exception exit path — it
  `throw`s for a widget named `"throw"` and `exit`s for one named `"exit"` (any
  other name produces normally). Used to prove that `capture_isolation?` catches a
  producer's throw/exit (not just a raise), and that WITHOUT isolation those same
  failures still roll the host transaction back. Wired to `test.isolated_erratic`
  (isolation on) and `test.coupled_erratic` (isolation off) on
  `Example.Catalog.Widget`; inert unless something subscribes.
  """
  use AshIntegration.Outbound.Declare.Producer

  @impl true
  def produce(_version, pairs, _context) do
    Map.new(pairs, fn {_changeset, record} ->
      case record.name do
        "throw" -> throw(:erratic_throw)
        "exit" -> exit(:erratic_exit)
        _ -> {record.id, %{id: record.id}}
      end
    end)
  end

  @impl true
  def example(_version), do: %{id: "x"}

  @impl true
  def event_key(_version, %{id: id}), do: to_string(id)

  @impl true
  def project(events, _subscriptions, _context), do: Map.new(events, &{&1.id, :deliver})
end
