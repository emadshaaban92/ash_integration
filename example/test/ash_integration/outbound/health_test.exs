defmodule Example.Outbound.HealthTest do
  @moduledoc """
  DB-backed coverage for derived suspension (`design/connection-health.md`): the
  recompute trip signal (§5), park-on-suspend (§6), and the bounded probe (§7).
  Suspension is no longer an inline counter — it is recomputed from the delivery
  `Log` ("no success among the last N transport/response outcomes").
  """
  use Example.DataCase, async: false

  alias AshIntegration.Outbound.Delivery.Health
  alias Example.Outbound.{Connection, Log, Subscription}

  setup do
    %{connection: create_connection!(create_user!())}
  end

  describe "recompute — derived trip signal" do
    test "suspends only after N transport failures; a success clears it", %{connection: dest} do
      with_window(2, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        ev = create_event!(s1, state: :scheduled)

        record_failure!(ev, "transport")
        Health.recompute()
        refute reload(dest).suspended, "1 failure < N=2 must not trip"

        record_failure!(reload(ev), "transport")
        Health.recompute()
        assert reload(dest).suspended, "2 failures >= N=2 trips"
        refute reload(s1).suspended

        # A logged success is what clears it on the next recompute.
        schedule!(reload(ev))
        deliver!(reload(ev))
        Health.recompute()
        refute reload(dest).suspended
      end)
    end

    test "a response rejection scopes to the subscription, not the connection",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        record_failure!(create_event!(s1, state: :scheduled), "response")

        Health.recompute()

        assert reload(s1).suspended
        refute reload(dest).suspended
        assert [%{status: :failed, failure_class: :response}] = logs()
      end)
    end

    test "an unclassified failure defaults to the subscription (narrower blast radius)",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        record_failure!(create_event!(s1, state: :scheduled), nil)

        Health.recompute()

        assert reload(s1).suspended
        refute reload(dest).suspended
      end)
    end

    test "recompute is transition-only — a re-run does not re-stamp suspended_at",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        record_failure!(create_event!(s1, state: :scheduled), "transport")

        Health.recompute()
        first = reload(dest).suspended_at
        assert first

        Health.recompute()
        assert reload(dest).suspended_at == first
      end)
    end
  end

  describe "park on the suspend transition" do
    test "un-leased :scheduled rows revert to pending; a live-leased row drains",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        unleased = create_event!(s1, event_key: "a", state: :scheduled)
        leased = create_event!(s1, event_key: "b", state: :scheduled)
        stamp_claimed!(leased, DateTime.utc_now())

        record_failure!(unleased, "transport")
        Health.recompute()

        assert reload(dest).suspended
        assert reload(unleased).state == :pending, "un-leased row parked back to pending"
        assert reload(leased).state == :scheduled, "live-leased row left to drain"
      end)
    end
  end

  describe "bounded probe" do
    test "promotes one pending head for a suspended connection; a probe success recovers it",
         %{connection: dest} do
      with_window(1, fn ->
        s1 = create_subscription!(dest, "widget.updated")
        ev = create_event!(s1, event_key: "p1", state: :scheduled)

        record_failure!(ev, "transport")
        Health.recompute()
        assert reload(dest).suspended
        assert reload(ev).state == :pending, "parked on suspend"

        Health.probe()
        assert reload(ev).state == :scheduled, "exactly one probe promoted"

        deliver!(reload(ev))
        Health.recompute()
        refute reload(dest).suspended, "observed success clears suspension"
      end)
    end

    test "probe load is bounded by probe_batch, independent of how many are suspended",
         %{connection: dest} do
      with_health([window_attempts: 1, probe_batch: 1], fn ->
        other = create_connection!(create_user!())

        # dest fails first → older last-log → probed first under round-robin.
        d1 = create_event!(create_subscription!(dest, "widget.updated"), state: :scheduled)
        record_failure!(d1, "transport")
        Health.recompute()

        d2 = create_event!(create_subscription!(other, "widget.updated"), state: :scheduled)
        record_failure!(d2, "transport")
        Health.recompute()

        assert reload(dest).suspended and reload(other).suspended

        Health.probe()

        scheduled = Enum.count([reload(d1), reload(d2)], &(&1.state == :scheduled))
        assert scheduled == 1, "probe_batch=1 promotes exactly one probe across the suspended set"
      end)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp with_window(n, fun), do: with_health([window_attempts: n], fun)

  defp with_health(opts, fun) do
    prev = Application.get_env(:ash_integration, :health)
    Application.put_env(:ash_integration, :health, opts)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_integration, :health, prev),
        else: Application.delete_env(:ash_integration, :health)
    end)

    fun.()
  end

  defp record_failure!(event, failure_class) do
    metadata = if failure_class, do: %{"failure_class" => failure_class}, else: %{}

    Ash.update!(
      Ash.Changeset.for_update(
        event,
        :record_attempt_error,
        %{last_error: "boom", delivery_metadata: metadata},
        authorize?: false
      ),
      authorize?: false
    )
  end

  defp schedule!(event) do
    Ash.update!(Ash.Changeset.for_update(event, :schedule, %{}, authorize?: false),
      authorize?: false
    )
  end

  defp deliver!(event) do
    Ash.update!(
      Ash.Changeset.for_update(event, :deliver, %{delivery_metadata: %{}}, authorize?: false),
      authorize?: false
    )
  end

  defp stamp_claimed!(delivery, at) do
    Example.Repo.update_all(
      from(d in "outbound_event_deliveries", where: d.id == type(^delivery.id, Ecto.UUID)),
      set: [claimed_at: at]
    )
  end

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "t-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
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

  defp create_subscription!(dest, event_type) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: dest.id,
        event_type: event_type,
        version: 1,
        transform_source: "function transform(event, defaults) return event end"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_event!(subscription, overrides), do: build_delivery!(subscription, overrides)

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)

  defp logs, do: Log |> Ash.read!(authorize?: false)
end
