defmodule Example.Outbound.DeliveryLogIndexLiveTest do
  @moduledoc """
  Mounted-view coverage for the Delivery Logs views:

    * `DeliveryLogLive.All` — the index filter round-trips (status, connection) and
      the P3 `since` time-window filter, which time-boxes the list so a dashboard
      "(24h)" drill-down shows exactly the rows the tile counted.
    * `DeliveryLogLive.Show` — the P3 Duration "—" fallback on a nil duration.
    * `DeliveryLive.Show` attempts table — the P3 newest-first `logs` ordering.
  """
  use ExampleWeb.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import Example.DataCase, only: [build_delivery!: 2, build_log!: 2]
  import Example.IntegrationHelpers, only: [create_user!: 0]

  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  @logs_path "/integrations/logs"

  setup %{conn: conn} do
    user = create_user!()
    %{conn: log_in(conn, user), user: user}
  end

  describe "index listing + status filter" do
    test "lists logs and the status filter round-trips through the URL", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      build_log!(sub, %{status: :success, response_status: 201})
      build_log!(sub, %{status: :failed, response_status: 503})

      # Unfiltered: both attempts show.
      {:ok, _view, html} = live(conn, @logs_path)
      assert html =~ "201"
      assert html =~ "503"

      # Filtered to success: only the 2xx attempt survives.
      {:ok, _view, html} = live(conn, @logs_path <> "?status=success")
      assert html =~ "201"
      refute html =~ "503"
    end

    test "the connection filter narrows to one connection's logs", %{conn: conn, user: user} do
      sub_a = create_subscription!(create_connection!(user), "widget.updated")
      sub_b = create_subscription!(create_connection!(user), "stock.changed")
      build_log!(sub_a, %{status: :success, response_status: 211})
      build_log!(sub_b, %{status: :success, response_status: 222})

      {:ok, _view, html} = live(conn, @logs_path <> "?connection=#{sub_a.connection_id}")

      assert html =~ "211"
      refute html =~ "222"
    end
  end

  describe "since time-window filter (matches the dashboard 24h tiles)" do
    test "?since=24h drops logs older than the window", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      build_log!(sub, %{status: :success, response_status: 201})
      build_log!(sub, %{status: :success, response_status: 418, created_at: hours_ago(30)})

      # The dashboard "Delivered (24h)" tile drills in here:
      {:ok, _view, html} = live(conn, @logs_path <> "?status=success&since=24h")
      assert html =~ "201"
      refute html =~ "418"

      # Without the window, the older attempt is back.
      {:ok, _view, html} = live(conn, @logs_path <> "?status=success")
      assert html =~ "201"
      assert html =~ "418"
    end

    test "an unknown since value is ignored (no accidental empty list)", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      build_log!(sub, %{status: :success, response_status: 201, created_at: hours_ago(100)})

      {:ok, _view, html} = live(conn, @logs_path <> "?since=bogus")
      assert html =~ "201"
    end
  end

  describe "log show — Duration fallback" do
    test "a nil duration renders the em-dash fallback, a real one renders ms",
         %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      # Give it a real response_status so the only em-dash on the page is Duration's.
      no_duration = build_log!(sub, %{status: :success, response_status: 204, duration_ms: nil})
      timed = build_log!(sub, %{status: :success, response_status: 200, duration_ms: 137})

      {:ok, _view, html} = live(conn, "#{@logs_path}/#{no_duration.id}")
      assert html =~ "Duration"
      assert html =~ "—"

      {:ok, _view, html} = live(conn, "#{@logs_path}/#{timed.id}")
      assert html =~ "137 ms"
    end
  end

  describe "delivery attempts table — newest-first" do
    test "the delivery's logs load newest-first (id: :desc)", %{user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :failed})

      # Seed in occurrence order; uuidv7 ids ascend with insertion.
      _first = build_log!(sub, %{status: :failed, event_delivery_id: delivery.id})
      _second = build_log!(sub, %{status: :failed, event_delivery_id: delivery.id})
      _third = build_log!(sub, %{status: :success, event_delivery_id: delivery.id})

      loaded =
        EventDelivery
        |> Ash.Query.filter(id == ^delivery.id)
        |> Ash.Query.load(:logs)
        |> Ash.read_one!(authorize?: false)

      ids = Enum.map(loaded.logs, & &1.id)
      assert ids == Enum.sort(ids, :desc), "delivery.logs must be newest-first"
    end

    test "the delivery show page renders the attempts newest-first", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :failed})

      build_log!(sub, %{status: :failed, response_status: 511, event_delivery_id: delivery.id})
      build_log!(sub, %{status: :success, response_status: 533, event_delivery_id: delivery.id})

      {:ok, _view, html} = live(conn, "/integrations/deliveries/#{delivery.id}")

      # Newest attempt (533, seeded last) appears above the older one (511).
      assert html =~ "533"
      assert html =~ "511"
      {newest, _} = :binary.match(html, "533")
      {oldest, _} = :binary.match(html, "511")
      assert newest < oldest
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n, :hour)

  defp log_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
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
        transform_source: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
