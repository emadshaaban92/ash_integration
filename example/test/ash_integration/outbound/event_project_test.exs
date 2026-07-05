defmodule Example.Outbound.EventProjectTest do
  @moduledoc """
  Coverage for the producer's `project/3` hook at dispatch (§5) — the single
  host-owned authz + routing decision. Exercised via `Example.Outbound.Scoped`,
  whose decision is selected by the widget `name`:

    * `"deliver"` → an `EventDelivery` is materialized;
    * `"skip"`    → `{:skip, _}` ⇒ NO delivery (the immutable Event is the audit);
    * `"omit"`    → the event id is absent from the result ⇒ fail-closed skip;
    * `"raise"`   → `project` raises ⇒ deliveries are created `:parked`.
  """
  use Example.DataCase, async: false

  import Example.IntegrationHelpers, only: [create_user!: 0]

  require Ash.Query

  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, EventDelivery, Event, Subscription}

  setup do
    dest = create_connection!(create_user!())
    %{sub: create_subscription!(dest)}
  end

  test "a :deliver decision materializes an EventDelivery", %{sub: sub} do
    create_widget!("deliver")
    drain_dispatch!()

    assert [%{state: :pending}] = deliveries_for(sub)
    # The immutable Event (the fact) always exists, regardless of the decision.
    assert Ash.count!(Event, authorize?: false) == 1
  end

  test "a {:skip, _} decision creates NO delivery — the Event remains as the audit", %{sub: sub} do
    create_widget!("skip")
    drain_dispatch!()

    assert deliveries_for(sub) == []
    assert Ash.count!(Event, authorize?: false) == 1
  end

  test "fail-closed: an event id omitted from the result is treated as skip", %{sub: sub} do
    create_widget!("omit")
    drain_dispatch!()

    assert deliveries_for(sub) == []
    assert Ash.count!(Event, authorize?: false) == 1
  end

  test "a project that raises parks the candidate deliveries", %{sub: sub} do
    create_widget!("raise")
    drain_dispatch!()

    assert [%{state: :parked, delivery: nil, last_error: error}] = deliveries_for(sub)
    assert error =~ "project error"
  end

  test "a non-map projection parks (fail-closed) instead of shipping full data", %{sub: sub} do
    # `{:deliver, <non-map>}` is most likely a botched redaction. The redaction
    # boundary must fail closed — park, never broadcast the unredacted `data`.
    create_widget!("bad_projection")
    drain_dispatch!()

    assert [%{state: :parked, delivery: nil, last_error: error}] = deliveries_for(sub)
    assert error =~ "invalid decision"
  end

  test "an unrecognized decision shape parks instead of crashing the job", %{sub: sub} do
    # A malformed return must not raise uncaught (which would retry then silently
    # discard with no audit) — it parks, recoverable via reprocess.
    create_widget!("bad_decision")
    drain_dispatch!()

    assert [%{state: :parked, delivery: nil, last_error: error}] = deliveries_for(sub)
    assert error =~ "invalid decision"
  end

  test "a project that returns a non-map parks the candidates (no BadMapError)", %{sub: sub} do
    # `project/3` is contracted to return a `%{event_id => decision}` map. A non-map
    # return used to raise a BadMapError out of the processor's `Map.get`; it must
    # instead take the documented fail-closed park-all path.
    create_widget!("non_map")
    drain_dispatch!()

    assert [%{state: :parked, delivery: nil, last_error: error}] = deliveries_for(sub)
    assert error =~ "project error"
    assert error =~ "non-map"
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp deliveries_for(sub) do
    EventDelivery
    |> Ash.Query.filter(subscription_id == ^sub.id)
    |> Ash.read!(authorize?: false)
  end

  defp create_widget!(name) do
    Widget
    |> Ash.Changeset.for_create(:create, %{name: name, stock: 1}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_subscription!(dest) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: "widget.scoped",
        version: 1,
        transform_source: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "http://localhost:9999/webhook",
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
