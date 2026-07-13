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
      ok = build_log!(sub, %{status: :success, response_status: 201})
      err = build_log!(sub, %{status: :failed, response_status: 503})

      # Match the specific row elements (`#log-<id>`), not a bare 3-char status
      # substring against the whole page — it can collide with session tokens,
      # UUIDs, or timestamps elsewhere in the HTML.
      #
      # Unfiltered: both attempts show.
      {:ok, view, _html} = live(conn, @logs_path)
      assert has_element?(view, "#log-#{ok.id}")
      assert has_element?(view, "#log-#{err.id}")

      # Filtered to success: only the 2xx attempt survives.
      {:ok, view, _html} = live(conn, @logs_path <> "?status=success")
      assert has_element?(view, "#log-#{ok.id}")
      refute has_element?(view, "#log-#{err.id}")
    end

    test "the connection filter narrows to one connection's logs", %{conn: conn, user: user} do
      sub_a = create_subscription!(create_connection!(user), "widget.updated")
      sub_b = create_subscription!(create_connection!(user), "stock.changed")
      log_a = build_log!(sub_a, %{status: :success, response_status: 211})
      log_b = build_log!(sub_b, %{status: :success, response_status: 222})

      {:ok, view, _html} = live(conn, @logs_path <> "?connection=#{sub_a.connection_id}")

      # Match the specific row elements, not a bare substring against the whole
      # page: the response status is only 3 chars and can collide with session
      # tokens, UUIDs, or timestamps elsewhere in the HTML.
      assert has_element?(view, "#log-#{log_a.id}")
      refute has_element?(view, "#log-#{log_b.id}")
    end
  end

  describe "since time-window filter (matches the dashboard 24h tiles)" do
    test "?since=24h drops logs older than the window", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      recent = build_log!(sub, %{status: :success, response_status: 201})
      old = build_log!(sub, %{status: :success, response_status: 418, created_at: hours_ago(30)})

      # The dashboard "Delivered (24h)" tile drills in here:
      {:ok, view, _html} = live(conn, @logs_path <> "?status=success&since=24h")
      assert has_element?(view, "#log-#{recent.id}")
      refute has_element?(view, "#log-#{old.id}")

      # Without the window, the older attempt is back.
      {:ok, view, _html} = live(conn, @logs_path <> "?status=success")
      assert has_element?(view, "#log-#{recent.id}")
      assert has_element?(view, "#log-#{old.id}")
    end

    test "an unknown since value is ignored (no accidental empty list)", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      log = build_log!(sub, %{status: :success, response_status: 201, created_at: hours_ago(100)})

      {:ok, view, _html} = live(conn, @logs_path <> "?since=bogus")
      assert has_element?(view, "#log-#{log.id}")
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

      older =
        build_log!(sub, %{status: :failed, response_status: 511, event_delivery_id: delivery.id})

      newer =
        build_log!(sub, %{status: :success, response_status: 533, event_delivery_id: delivery.id})

      {:ok, _view, html} = live(conn, "/integrations/deliveries/#{delivery.id}")

      # Compare row positions by their unique log ids (each renders in the row's
      # "View" link) rather than the 3-digit statuses, which can collide with
      # tokens/UUIDs elsewhere on the page. The newer attempt (seeded last, so a
      # larger uuidv7 id) must render above the older one.
      {newest, _} = :binary.match(html, newer.id)
      {oldest, _} = :binary.match(html, older.id)
      assert newest < oldest, "delivery attempts must render newest-first"
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
