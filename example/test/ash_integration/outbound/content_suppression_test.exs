defmodule Example.Outbound.ContentSuppressionTest do
  @moduledoc """
  Tests for content-addressed delivery suppression (`suppress_unchanged`):

    * `Dedup.hash/1` is canonical (stable across map key order);
    * an opted-in subscription withholds a delivery whose body equals the LAST
      DELIVERED body on the lane — recording it as `:suppressed` (not `:delivered`),
      with no transport call and no failure-counter reset;
    * a value that recurs (`5 → 6 → 5`) still delivers (baseline is last-delivered);
    * an opted-OUT subscription always delivers, even with identical bodies;
    * a transform-returned `dedup_on` overrides the body as the comparison target.
  """
  use Example.DataCase, async: false

  require Ash.Query

  import Example.IntegrationHelpers,
    only: [create_user!: 0, stub_webhook_success: 0, stub_webhook_capture: 1]

  alias AshIntegration.Outbound.Delivery.Dedup
  alias AshIntegration.Outbound.Delivery.Resolver
  alias AshIntegration.Outbound.Delivery.Scheduler
  alias AshIntegration.Outbound.Wire.Envelope
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  setup do
    owner = create_user!()
    %{owner: owner, connection: create_connection!(owner)}
  end

  describe "Dedup.hash/1" do
    test "is stable across map key order" do
      assert Dedup.hash(%{"a" => 1, "b" => 2}) == Dedup.hash(%{"b" => 2, "a" => 1})
    end

    test "is stable across nested map key order" do
      assert Dedup.hash(%{"o" => %{"x" => 1, "y" => 2}}) ==
               Dedup.hash(%{"o" => %{"y" => 2, "x" => 1}})
    end

    test "differs for different content" do
      refute Dedup.hash(%{"stock" => 5}) == Dedup.hash(%{"stock" => 6})
    end

    test "distinguishes a missing key from a nil value" do
      refute Dedup.hash(%{"a" => 1}) == Dedup.hash(%{"a" => 1, "b" => nil})
    end
  end

  describe "suppress_unchanged: true" do
    test "withholds an identical repeat: :suppressed, no send, suppressed log", ctx do
      stub_webhook_capture(self())
      sub = create_subscription!(ctx.connection, suppress_unchanged: true)

      first = deliver!(sub, %{"stock" => 5})
      assert reload(first).state == :delivered
      assert_received {:webhook_request, _}

      second = deliver!(sub, %{"stock" => 5})
      reloaded = reload(second)
      assert reloaded.state == :suppressed
      # No bytes went out for the suppressed delivery.
      refute_received {:webhook_request, _}

      # A :suppressed log row records the withheld delivery for the drill-down.
      assert [log] = logs_for(second)
      assert log.status == :suppressed
    end

    test "a recurring value (5 -> 6 -> 5) still delivers — baseline is last-delivered", ctx do
      stub_webhook_capture(self())
      sub = create_subscription!(ctx.connection, suppress_unchanged: true)

      assert reload(deliver!(sub, %{"stock" => 5})).state == :delivered
      assert reload(deliver!(sub, %{"stock" => 6})).state == :delivered
      # The last DELIVERED body is now 6, so 5 is a real change again.
      assert reload(deliver!(sub, %{"stock" => 5})).state == :delivered

      # Three real sends, none suppressed.
      assert_received {:webhook_request, _}
      assert_received {:webhook_request, _}
      assert_received {:webhook_request, _}
    end

    test "a suppression writes a neutral :suppressed log (excluded from health windows)", ctx do
      stub_webhook_success()
      sub = create_subscription!(ctx.connection, suppress_unchanged: true)

      # Baseline real send, then an identical body suppresses.
      deliver!(sub, %{"stock" => 5})
      suppressed = reload(deliver!(sub, %{"stock" => 5}))
      assert suppressed.state == :suppressed

      # The log is `:suppressed` (not success/failure), so the derived-health windows
      # — successes ∪ transport/response failures — ignore it: a suppression touches
      # no transport and neither trips nor clears a suspension.
      assert [%{status: :suppressed, failure_class: nil}] = logs_for(suppressed)
    end

    test "dedup_on overrides the body as the comparison target", ctx do
      stub_webhook_capture(self())
      # Compare only on data.stock; the noisy `seq` field must not defeat suppression.
      script = ~S"""
      function transform(event, defaults)
        defaults.dedup_on = { stock = event.data.stock }
        return defaults
      end
      """

      sub =
        create_subscription!(ctx.connection, suppress_unchanged: true, transform_source: script)

      assert reload(deliver!(sub, %{"stock" => 5, "seq" => 1})).state == :delivered
      assert_received {:webhook_request, _}

      # Body differs (seq 1 -> 2) but dedup_on (stock) is unchanged → suppressed.
      assert reload(deliver!(sub, %{"stock" => 5, "seq" => 2})).state == :suppressed
      refute_received {:webhook_request, _}
    end
  end

  describe "schedule-time resolution" do
    test "the scheduler suppresses an unchanged head (pending -> suppressed, never scheduled)",
         ctx do
      stub_webhook_success()
      sub = create_subscription!(ctx.connection, suppress_unchanged: true)

      # Baseline on lane p1 (a real delivery), then two pending heads on distinct
      # lanes: p1 repeats the baseline (→ suppressed at promote), p2 is new (→ scheduled).
      deliver!(sub, %{"stock" => 5})
      dup = pending_delivery!(sub, %{"stock" => 5}, "p1")
      fresh = pending_delivery!(sub, %{"stock" => 9}, "p2")

      Scheduler.sweep()

      # The unchanged head went straight to :suppressed — it never became :scheduled,
      # so it never entered the delivery relay. The genuine change is scheduled.
      assert reload(dup).state == :suppressed
      assert reload(fresh).state == :scheduled
    end
  end

  describe "suppress_unchanged: false (default)" do
    test "always delivers, even for identical bodies", ctx do
      stub_webhook_capture(self())
      sub = create_subscription!(ctx.connection, suppress_unchanged: false)

      assert reload(deliver!(sub, %{"stock" => 5})).state == :delivered
      assert reload(deliver!(sub, %{"stock" => 5})).state == :delivered

      assert_received {:webhook_request, _}
      assert_received {:webhook_request, _}
      assert is_nil(reload(deliver!(sub, %{"stock" => 5})) |> Map.get(:body_hash))
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Create a :pending delivery for `data`, run the scheduler (which suppresses it if
  # its body is unchanged, else schedules it), then drain any scheduled send. Returns
  # the (pre-sweep) delivery struct. Sequential calls share the lane safely because
  # each pass leaves the previous row terminal before the next is created.
  defp deliver!(subscription, data) do
    delivery = pending_delivery!(subscription, data)
    Scheduler.sweep()
    drain_delivery!()
    delivery
  end

  defp pending_delivery!(subscription, data, event_key \\ "p1") do
    subscription = Ash.load!(subscription, [:connection], authorize?: false)

    event =
      Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          event_type: subscription.event_type,
          version: subscription.version,
          event_key: event_key,
          source_resource: "widget",
          source_resource_id: "r1",
          source_action: "update",
          data: data,
          dispatched_at: DateTime.utc_now()
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    envelope =
      Envelope.transform_input(%{
        id: event.id,
        type: subscription.event_type,
        version: subscription.version,
        event_key: event_key,
        created_at: event.created_at,
        subject: "r1",
        data: data
      })

    {:ok, delivery, body_hash} =
      Resolver.resolve(subscription.connection, subscription, envelope, event.created_at)

    EventDelivery
    |> Ash.Changeset.for_create(
      :create,
      %{
        event_id: event.id,
        event_type: subscription.event_type,
        version: subscription.version,
        event_key: event_key,
        delivery: delivery,
        body_hash: body_hash,
        state: :pending,
        subscription_id: subscription.id,
        connection_id: subscription.connection_id
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

  defp create_subscription!(conn, opts) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: conn.id,
        event_type: "widget.updated",
        version: 1,
        transform_source: Keyword.get(opts, :transform_source, "-- noop"),
        suppress_unchanged: Keyword.fetch!(opts, :suppress_unchanged)
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp logs_for(delivery) do
    AshIntegration.delivery_log_resource()
    |> Ash.Query.filter(event_delivery_id == ^delivery.id)
    |> Ash.read!(authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)
end
