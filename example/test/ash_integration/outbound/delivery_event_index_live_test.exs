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
    test "renders a row's fields + badge, and its projection drops the blobs", ctx do
      %{conn: conn, user: user} = ctx
      connection = create_connection!(user)
      sub = create_subscription!(connection, "widget.updated")

      delivery =
        build_delivery!(sub, %{
          event_key: "row-key-1",
          state: :delivered,
          delivery: %{"wire" => "x"}
        })

      {:ok, view, _html} = live(conn, @deliveries_path)

      # Scope assertions to this row's element (not the whole page) so an incidental
      # substring elsewhere can't pass/fail them — the flakiness class #105 fixed.
      row_sel = "#delivery-#{delivery.id}"
      assert has_element?(view, row_sel, "widget.updated")
      assert has_element?(view, row_sel, "row-key-1")
      # The strict `[connection: [:name]]` load still populates the rendered name.
      assert has_element?(view, row_sel, connection.name)
      # State badge — reads `state` (selected).
      assert has_element?(view, row_sel, "Delivered")

      # Assert against the row the VIEW actually loaded (not a query we build here),
      # so reverting the view's `select` makes this fail. The blobs must be unloaded;
      # the displayed fields must be present.
      [row] = mounted_rows(view, :deliveries)
      assert match?(%Ash.NotLoaded{}, row.delivery)
      assert match?(%Ash.NotLoaded{}, row.delivery_metadata)
      assert row.event_type == "widget.updated"
      assert row.connection.name == connection.name
    end

    test "a terminal delivery renders the Terminal badge (terminal_reason selected)", ctx do
      %{conn: conn, user: user} = ctx
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :failed, terminal_reason: :permanent})

      {:ok, view, _html} = live(conn, @deliveries_path)

      # Terminal badge reads `state` + `terminal_reason` — both must be selected or
      # the badge would silently fall through to the plain "Retrying" state.
      assert has_element?(view, "#delivery-#{delivery.id}", "Terminal")
    end
  end

  describe "/events list" do
    test "renders a row's fields + dispatched badge, and its projection drops `data`", ctx do
      %{conn: conn, user: user} = ctx
      sub = create_subscription!(create_connection!(user), "widget.updated")
      # build_delivery! seeds the parent Event (with `data`) and stamps dispatched_at.
      delivery =
        build_delivery!(sub, %{
          event_key: "evt-key-1",
          source_resource: "widget",
          data: %{"s" => "x"}
        })

      {:ok, view, _html} = live(conn, @events_path)

      # Row-scoped: "Dispatched" also appears as an outbox-filter <option>, so a
      # page-wide substring check would pass even if no row rendered.
      row_sel = "#event-#{delivery.event_id}"
      assert has_element?(view, row_sel, "widget.updated")
      assert has_element?(view, row_sel, "evt-key-1")
      assert has_element?(view, row_sel, "widget")
      # Outbox badge reads `dispatched_at` + `dispatch_terminal_reason` — both selected.
      assert has_element?(view, row_sel, "Dispatched")

      # The row the VIEW loaded must have the `data` payload blob unloaded.
      [row] = mounted_rows(view, :events)
      assert match?(%Ash.NotLoaded{}, row.data)
      assert row.event_type == "widget.updated"
    end
  end

  # The rows the mounted LiveView actually loaded into its socket assigns — the real
  # output of the view's query, so a reverted `select` would surface here.
  defp mounted_rows(view, assign_key) do
    :sys.get_state(view.pid).socket.assigns[assign_key]
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
