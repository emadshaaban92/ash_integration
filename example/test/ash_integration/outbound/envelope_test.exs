defmodule Example.Outbound.EnvelopeTest do
  @moduledoc """
  The shared Lua-transform input builder (§7). Both the dispatcher and the
  reprocessor go through `Envelope.transform_input/1` so the transform sees a
  byte-identical input on both paths, and provenance never leaks into it.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Outbound.Wire.Envelope

  test "drops provenance and normalizes created_at so both call sites agree" do
    dt = ~U[2026-05-31 12:00:00.123456Z]
    iso = DateTime.to_iso8601(dt)

    # A caller may pass created_at as an ISO8601 string.
    dispatch =
      Envelope.transform_input(%{
        id: "e1",
        type: "widget.updated",
        version: 1,
        event_key: "k1",
        created_at: iso,
        subject: "r1",
        data: %{"x" => 1}
      })

    # Reprocess passes the Event's stored DateTime, plus a stray provenance map
    # that must be ignored — never surfaced to the transform (§7).
    reprocess =
      Envelope.transform_input(%{
        id: "e1",
        type: "widget.updated",
        version: 1,
        event_key: "k1",
        created_at: dt,
        subject: "r1",
        data: %{"x" => 1},
        source: %{resource: "widget", action: "update"}
      })

    assert dispatch == reprocess
    refute Map.has_key?(dispatch, :source)
    assert dispatch.created_at == iso

    assert Map.keys(dispatch) |> Enum.sort() == [
             :created_at,
             :data,
             :event_key,
             :id,
             :subject,
             :type,
             :version
           ]
  end
end
