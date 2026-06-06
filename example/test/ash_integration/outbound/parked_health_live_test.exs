defmodule Example.Outbound.ParkedHealthLiveTest do
  @moduledoc """
  The parked-health dimension as the operator sees it: a chronically/broken
  subscription surfaces a non-healthy badge on the subscriptions index + detail and
  a "Parked" backlog count on the dashboard — and all of it CLEARS once the build is
  fixed and the parked deliveries are reprocessed.
  """
  use ExampleWeb.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import Example.DataCase

  alias AshIntegration.Outbound.Delivery.Reprocessor
  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, Subscription}

  @dashboard_path "/integrations"
  @subscriptions_path "/integrations/subscriptions"

  setup %{conn: conn} do
    user = create_user!()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    connection = create_connection!(user)
    %{conn: conn, connection: connection}
  end

  test "a parked subscription shows a non-healthy badge on the index that clears after reprocess",
       %{conn: conn, connection: dest} do
    sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    # Parked → the index calls out the degraded health (the blind spot the feature
    # closes: previously the row read fully active/green).
    {:ok, _view, html} = live(conn, @subscriptions_path)
    assert html =~ "Degraded"

    # Fix the build and clear the backlog.
    fix_transform!(sub, "-- noop")
    assert %{reprocessed: 1, failed: 0} = Reprocessor.reprocess_parked_for_connection(dest.id)

    {:ok, _view, html} = live(conn, @subscriptions_path)
    refute html =~ "Degraded"
    refute html =~ "Parked ("
  end

  test "the subscription detail page shows the parked count and clears after reprocess",
       %{conn: conn, connection: dest} do
    sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    {:ok, _view, html} = live(conn, "#{@subscriptions_path}/#{sub.id}")
    assert html =~ "Parked deliveries"
    assert html =~ "Degraded"

    fix_transform!(sub, "-- noop")
    Reprocessor.reprocess_parked_for_connection(dest.id)

    {:ok, _view, html} = live(conn, "#{@subscriptions_path}/#{sub.id}")
    refute html =~ "Degraded"
  end

  test "the dashboard surfaces the parked backlog count and clears after reprocess",
       %{conn: conn, connection: dest} do
    sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
    create_widget!(%{name: "w", stock: 1})
    drain_dispatch!()

    {:ok, _view, html} = live(conn, @dashboard_path)
    # The standing "Parked" stat (next to "Suppressed (24h)").
    assert html =~ "build failures awaiting reprocess"
    assert parked_stat_value(html) == "1"

    fix_transform!(sub, "-- noop")
    Reprocessor.reprocess_parked_for_connection(dest.id)

    {:ok, _view, html} = live(conn, @dashboard_path)
    assert parked_stat_value(html) == "0"
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Pull the "Parked" stat's value out of the dashboard stats row.
  defp parked_stat_value(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".stat")
    |> Enum.find_value(fn stat ->
      frag = LazyHTML.from_fragment(LazyHTML.to_html(stat))
      title = frag |> LazyHTML.query(".stat-title") |> LazyHTML.text() |> String.trim()

      if title == "Parked",
        do: frag |> LazyHTML.query(".stat-value") |> LazyHTML.text() |> String.trim()
    end)
  end

  defp fix_transform!(sub, script) do
    sub
    |> Ash.Changeset.for_update(:update, %{transform_source: script}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "ph-#{System.unique_integer([:positive])}@x.com"},
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

  defp create_widget!(attrs) do
    Widget
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
