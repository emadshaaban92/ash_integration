defmodule Example.Outbound.ParkedHealthTest do
  @moduledoc """
  The standing parked-health dimension against real resources: the `parked_count` /
  `oldest_parked_at` aggregates, the derived `ParkedHealth.status/1`, and the opt-in
  parked-suspend. Park must surface as a non-healthy status WITHOUT bumping the
  transport/response `consecutive_failures` counter or suspending by default — and a
  reprocess that fixes the build must clear it.
  """
  # async: false — the parked-suspension tests mutate the global :ash_integration env.
  use Example.DataCase, async: false

  import Example.IntegrationHelpers, only: [create_user!: 0]

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.{ParkedHealth, Reprocessor}
  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  setup do
    %{connection: create_connection!(create_user!())}
  end

  describe "aggregates" do
    test "parked_count counts only :parked deliveries; oldest_parked_at is their min created_at",
         %{connection: dest} do
      sub = create_subscription!(dest, "widget.updated", "-- noop")

      first_parked = build_delivery!(sub, %{state: :parked, event_key: "a"})
      second_parked = build_delivery!(sub, %{state: :parked, event_key: "b"})
      _delivered = build_delivery!(sub, %{state: :delivered, event_key: "c"})
      _pending = build_delivery!(sub, %{state: :pending, event_key: "d"})

      loaded =
        Subscription
        |> Ash.Query.filter(id == ^sub.id)
        |> Ash.Query.load([:parked_count, :oldest_parked_at])
        |> Ash.read_one!(authorize?: false)

      assert loaded.parked_count == 2

      assert loaded.oldest_parked_at ==
               Enum.min([first_parked.created_at, second_parked.created_at], DateTime)
    end

    test "the connection aggregates span all its subscriptions", %{connection: dest} do
      sub_a = create_subscription!(dest, "widget.updated", "-- noop")
      sub_b = create_subscription!(dest, "stock.changed", "-- noop")

      build_delivery!(sub_a, %{state: :parked, event_key: "a"})
      build_delivery!(sub_b, %{state: :parked, event_key: "b"})
      build_delivery!(sub_b, %{state: :delivered, event_key: "c"})

      loaded =
        Connection
        |> Ash.Query.filter(id == ^dest.id)
        |> Ash.Query.load([:parked_count, :oldest_parked_at])
        |> Ash.read_one!(authorize?: false)

      assert loaded.parked_count == 2
      assert loaded.oldest_parked_at
    end

    test "parked_count is 0 (not nil) with no parked deliveries → :healthy", %{connection: dest} do
      sub = create_subscription!(dest, "widget.updated", "-- noop")
      build_delivery!(sub, %{state: :delivered})

      loaded = load_health(sub)
      assert loaded.parked_count == 0
      assert ParkedHealth.status(loaded) == :healthy
    end
  end

  describe "derived health from a broken transform (the blind spot)" do
    test "a subscription whose transform parks everything reads non-healthy with a parked count",
         %{connection: dest} do
      sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)

      create_widget!(%{name: "a", stock: 1})
      create_widget!(%{name: "b", stock: 1})
      drain_dispatch!()

      assert Enum.count(all_deliveries(), &(&1.state == :parked)) == 2

      loaded = load_health(sub)
      assert loaded.parked_count == 2
      assert ParkedHealth.status(loaded) in [:degraded, :parked]
      assert ParkedHealth.unhealthy?(loaded)

      # Park is NOT a transport/response failure — the failure counter and
      # suspension stay clean (the distinction the whole feature preserves).
      assert loaded.consecutive_failures == 0
      refute loaded.suspended
    end

    test "reprocess clears the parked backlog → health returns to :healthy", %{connection: dest} do
      sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
      create_widget!(%{name: "a", stock: 1})
      drain_dispatch!()

      assert ParkedHealth.unhealthy?(load_health(sub))

      fix_transform!(sub, "-- noop")
      assert %{reprocessed: 1, failed: 0} = Reprocessor.reprocess_parked_for_connection(dest.id)

      loaded = load_health(sub)
      assert loaded.parked_count == 0
      assert ParkedHealth.status(loaded) == :healthy
    end
  end

  describe "opt-in parked-suspend" do
    test "default OFF: a chronically parked subscription is visible but NOT suspended",
         %{connection: dest} do
      Application.delete_env(:ash_integration, :parked_suspension)

      sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
      for n <- 1..3, do: create_widget!(%{name: "w#{n}", stock: 1})
      drain_dispatch!()

      loaded = load_health(sub)
      assert loaded.parked_count == 3
      refute loaded.suspended, "parking must not auto-suspend when the opt-in is off"
    end

    test "enabled: crossing the threshold suspends WITHOUT bumping consecutive_failures",
         %{connection: dest} do
      enable_parked_suspension!(count_threshold: 2)

      sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)

      # A parked-suspend reuses the shared suspension event, tagged failure_class
      # "parked" so a suspension monitor catches the opt-in halt too.
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:ash_integration, :subscription, :suspended]
        ])

      for n <- 1..2, do: create_widget!(%{name: "w#{n}", stock: 1})
      drain_dispatch!()

      loaded = load_health(sub)
      assert loaded.parked_count == 2
      assert loaded.suspended, "a parked backlog past the threshold must parked-suspend"
      assert loaded.suspension_reason =~ "parked"
      # It is a parked-suspend, not a failure-counter suspend.
      assert loaded.consecutive_failures == 0

      assert_received {[:ash_integration, :subscription, :suspended], ^ref, measurements, meta}
      assert meta.id == sub.id
      assert meta.failure_class == "parked"
      assert meta.threshold == 2
      assert measurements.parked_count == 2
      assert measurements.consecutive_failures == 0
    end

    test "enabled but below the threshold does not suspend", %{connection: dest} do
      enable_parked_suspension!(count_threshold: 5)

      sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      loaded = load_health(sub)
      assert loaded.parked_count == 1
      refute loaded.suspended
    end

    test "a parked-suspended subscription is recoverable via reprocess + unsuspend",
         %{connection: dest} do
      enable_parked_suspension!(count_threshold: 1)

      sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      assert load_health(sub).suspended

      # Reprocess clears the backlog (build fixed); unsuspend resumes the lane.
      fix_transform!(sub, "-- noop")
      assert %{reprocessed: 1, failed: 0} = Reprocessor.reprocess_parked_for_connection(dest.id)

      # Reload before unsuspend — operate on the suspended row, not the stale
      # pre-suspend struct (as the dashboard does after re-fetching).
      Subscription
      |> Ash.get!(sub.id, authorize?: false)
      |> Ash.Changeset.for_update(:unsuspend, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      loaded = load_health(sub)
      assert loaded.parked_count == 0
      refute loaded.suspended
      assert ParkedHealth.status(loaded) == :healthy
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp load_health(sub) do
    Subscription
    |> Ash.Query.filter(id == ^sub.id)
    |> Ash.Query.load([:parked_count, :oldest_parked_at])
    |> Ash.read_one!(authorize?: false)
  end

  defp enable_parked_suspension!(opts) do
    original = Application.fetch_env(:ash_integration, :parked_suspension)

    Application.put_env(
      :ash_integration,
      :parked_suspension,
      Keyword.put(opts, :enabled?, true)
    )

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ash_integration, :parked_suspension, value)
        :error -> Application.delete_env(:ash_integration, :parked_suspension)
      end
    end)
  end

  defp fix_transform!(sub, script) do
    sub
    |> Ash.Changeset.for_update(:update, %{transform_source: script}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp all_deliveries,
    do: EventDelivery |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)

  defp create_subscription!(dest, event_type, transform_source) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_source: transform_source
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Plant a subscription whose transform raises at dispatch, PAST the save-time
  # smoke gate — these tests need parked deliveries, so seeding sets up that state
  # directly (mirrors ReprocessorTest).
  defp seed_subscription!(dest, event_type, transform_source) do
    Ash.Seed.seed!(Subscription, %{
      connection_id: dest.id,
      event_type: event_type,
      version: 1,
      transform_source: transform_source,
      active: true,
      suspended: false,
      consecutive_failures: 0
    })
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

  defp create_widget!(attrs) do
    Widget
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
