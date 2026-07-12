defmodule Example.Outbound.DashboardLiveTest do
  @moduledoc """
  Mounted-view coverage for the integrations dashboard (`DashboardLive`): the
  aggregate stat tiles load their counts, and the "(24h)" Delivered/Suppressed
  tiles are time-boxed and drill down into a matching, time-boxed Logs list (the
  `?since=24h` wiring — so the tile's number and the rows it lands on describe the
  same 24h window).
  """
  use ExampleWeb.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import Example.DataCase, only: [build_log!: 2]
  import Example.IntegrationHelpers, only: [create_user!: 0]

  alias Example.Outbound.{Connection, Subscription}

  @dashboard_path "/integrations"

  setup %{conn: conn} do
    user = create_user!()
    %{conn: log_in(conn, user), user: user}
  end

  describe "aggregate tiles" do
    test "mount loads and renders the stat tiles with their counts", %{conn: conn, user: user} do
      connection = create_connection!(user)
      create_subscription!(connection, "widget.updated")
      create_subscription!(connection, "stock.changed")

      {:ok, _view, html} = live(conn, @dashboard_path)

      # Every drill-down tile the operator relies on is present…
      for title <- [
            "Subscriptions",
            "Failing",
            "Delivered (24h)",
            "Suppressed (24h)",
            "Parked",
            "Terminal",
            "Connections"
          ] do
        assert html =~ title
      end

      # …and the aggregate actually loaded (two subscriptions, both active by default).
      assert html =~ "2 active"
    end

    test "Delivered (24h) counts only logs inside the 24h window", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")

      # One success inside the window, one older than 24h.
      build_log!(sub, %{status: :success})
      build_log!(sub, %{status: :success, created_at: hours_ago(30)})

      {:ok, view, _html} = live(conn, @dashboard_path)

      # The tile counts `created_at >= now-24h`, so only the recent log is counted.
      assert delivered_tile(view) =~ ~r/stat-value.*?>\s*1\s*</s
    end
  end

  describe "24h drill-down links" do
    test "Delivered / Suppressed tiles carry ?since=24h so the list matches the count",
         %{conn: conn, user: user} do
      create_subscription!(create_connection!(user), "widget.updated")

      {:ok, view, _html} = live(conn, @dashboard_path)

      assert has_element?(view, ~s|a[href*="status=success"][href*="since=24h"]|)
      assert has_element?(view, ~s|a[href*="status=suppressed"][href*="since=24h"]|)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp delivered_tile(view),
    do: view |> element(~s|a[href*="status=success"][href*="since=24h"]|) |> render()

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
