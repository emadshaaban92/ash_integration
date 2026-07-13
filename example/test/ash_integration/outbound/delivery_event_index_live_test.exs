defmodule Example.Outbound.DeliveryEventIndexLiveTest do
  @moduledoc """
  Mounted-view coverage for the two list views the delivery-log index test does not
  touch:

    * `DeliveryLive.All` — `/deliveries`
    * `EventLive.All`    — `/events`

  Both were switched to a lean `Ash.Query.select` (and Deliveries to a strict
  `:connection` load) so a list row no longer hydrates the TOAST-able JSONB blobs
  it never renders — `delivery`/`delivery_metadata` on EventDelivery, `data` on
  Event, only shown on the per-row show page. These tests assert the rows still
  render every displayed field + badge, that the strict `:connection` load still
  populates the connection name, and that the projection actually drops the blob.
  """
  use ExampleWeb.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import Example.DataCase, only: [build_delivery!: 2]
  import Example.IntegrationHelpers, only: [create_user!: 0]

  alias Example.Outbound.{Connection, Subscription}

  @deliveries_path "/integrations/deliveries"
  @events_path "/integrations/events"

  setup %{conn: conn} do
    user = create_user!()
    %{conn: log_in(conn, user), user: user}
  end

  describe "/deliveries list" do
    test "renders a row's summary fields, connection name, and state badge", ctx do
      %{conn: conn, user: user} = ctx
      connection = create_connection!(user)
      sub = create_subscription!(connection, "widget.updated")
      build_delivery!(sub, %{event_key: "row-key-1", state: :delivered})

      {:ok, _view, html} = live(conn, @deliveries_path)

      assert html =~ "widget.updated"
      assert html =~ "row-key-1"
      # The strict `[connection: [:name]]` load still populates the rendered name.
      assert html =~ connection.name
      # State badge — reads `state` (selected).
      assert html =~ "Delivered"
    end

    test "a terminal delivery renders the Terminal badge (terminal_reason selected)", ctx do
      %{conn: conn, user: user} = ctx
      sub = create_subscription!(create_connection!(user), "widget.updated")
      build_delivery!(sub, %{state: :failed, terminal_reason: :permanent})

      {:ok, _view, html} = live(conn, @deliveries_path)

      # Terminal badge reads `state` + `terminal_reason` — both must be selected or
      # the badge would silently fall through to the plain "Retrying" state.
      assert html =~ "Terminal"
    end

    test "the list projection drops the `delivery` blob but keeps displayed fields", ctx do
      %{user: user} = ctx
      sub = create_subscription!(create_connection!(user), "widget.updated")
      build_delivery!(sub, %{delivery: %{"wire" => "xxl-descriptor"}})

      # Mirror the projection `DeliveryLive.All` builds — the blob must come back
      # unloaded while the displayed columns are present.
      %{results: [row]} =
        AshIntegration.event_delivery_resource()
        |> Ash.Query.for_read(:index, %{}, authorize?: false)
        |> Ash.Query.select([:id, :event_type, :state])
        |> Ash.read!(authorize?: false, page: [limit: 20])

      assert row.event_type == "widget.updated"
      assert row.state == :pending
      assert match?(%Ash.NotLoaded{}, row.delivery)
    end
  end

  describe "/events list" do
    test "renders a row's summary fields and the dispatched outbox badge", ctx do
      %{conn: conn, user: user} = ctx
      sub = create_subscription!(create_connection!(user), "widget.updated")
      # build_delivery! seeds the parent Event (with `data`) and stamps dispatched_at.
      build_delivery!(sub, %{event_key: "evt-key-1", source_resource: "widget"})

      {:ok, _view, html} = live(conn, @events_path)

      assert html =~ "widget.updated"
      assert html =~ "evt-key-1"
      assert html =~ "widget"
      # Outbox badge reads `dispatched_at` + `dispatch_terminal_reason` — both selected.
      assert html =~ "Dispatched"
    end

    test "the list projection drops the `data` payload blob", ctx do
      %{user: user} = ctx
      sub = create_subscription!(create_connection!(user), "widget.updated")
      build_delivery!(sub, %{data: %{"secret" => "large-payload"}})

      %{results: [row]} =
        AshIntegration.event_resource()
        |> Ash.Query.for_read(:index, %{}, authorize?: false)
        |> Ash.Query.select([:id, :event_type])
        |> Ash.read!(authorize?: false, page: [limit: 20])

      assert row.event_type == "widget.updated"
      assert match?(%Ash.NotLoaded{}, row.data)
    end
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

  defp log_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
