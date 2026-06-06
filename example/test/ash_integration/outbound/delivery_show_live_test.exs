defmodule Example.Outbound.DeliveryShowLiveTest do
  @moduledoc """
  LiveView coverage for `DeliveryLive.Show`: the reprocess/reset/cancel handlers,
  the not-found redirect, and per-state action buttons.

  The example's EventDelivery uses `authorize_if always()`, so `can?/2` is always
  true here; the reprocess handler's not-authorized branch needs a restrictive
  policy fixture and is left as a follow-up.
  """
  use ExampleWeb.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import Example.DataCase, only: [build_delivery!: 2, drain_dispatch!: 0]
  import Example.IntegrationHelpers, only: [create_user!: 0]

  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  @index_path "/integrations/deliveries"

  setup %{conn: conn} do
    user = create_user!()
    %{conn: log_in(conn, user), user: user}
  end

  describe "rendering" do
    test "renders a delivery's event, key and state", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :delivered, event_key: "k-render"})

      {:ok, _view, html} = live(conn, show_path(delivery))

      assert html =~ "widget.updated"
      assert html =~ "k-render"
      assert html =~ "Delivered"
    end

    test "an unknown id redirects to the index with an error flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: @index_path, flash: flash}}} =
               live(conn, "#{@index_path}/#{Ash.UUID.generate()}")

      assert flash["error"] =~ "Delivery not found"
    end
  end

  describe "cancel" do
    test "cancels a pending delivery and reflects the new state", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :pending})

      {:ok, view, _html} = live(conn, show_path(delivery))

      html = view |> element("button[phx-click=cancel]") |> render_click()

      assert html =~ "Delivery cancelled"
      assert reload(delivery).state == :cancelled
    end
  end

  describe "reset" do
    test "resets a scheduled delivery back to pending", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :scheduled})

      {:ok, view, _html} = live(conn, show_path(delivery))

      html = view |> element("button[phx-click=reset]") |> render_click()

      assert html =~ "Delivery reset to pending"
      assert reload(delivery).state == :pending
    end
  end

  describe "reprocess" do
    test "re-runs a fixed transform and re-queues a parked delivery", %{conn: conn, user: user} do
      # Park it the realistic way: a transform that errors at dispatch.
      sub = seed_subscription!(create_connection!(user), "widget.updated", ~s|error("boom")|)
      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      parked = single_delivery()
      assert parked.state == :parked

      fix_transform!(sub, "-- noop")

      {:ok, view, _html} = live(conn, show_path(parked))
      html = view |> element("button[phx-click=reprocess]") |> render_click()

      assert html =~ "Delivery reprocessed and re-queued"
      assert reload(parked).state == :pending
    end
  end

  describe "action buttons per state" do
    test "a delivered delivery offers no state-changing actions", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :delivered})

      {:ok, _view, html} = live(conn, show_path(delivery))

      refute html =~ "phx-click=\"reprocess\""
      refute html =~ "phx-click=\"reset\""
      refute html =~ "phx-click=\"cancel\""
    end

    test "a scheduled delivery offers reset and cancel", %{conn: conn, user: user} do
      sub = create_subscription!(create_connection!(user), "widget.updated")
      delivery = build_delivery!(sub, %{state: :scheduled})

      {:ok, _view, html} = live(conn, show_path(delivery))

      assert html =~ "phx-click=\"reset\""
      assert html =~ "phx-click=\"cancel\""
      refute html =~ "phx-click=\"reprocess\""
    end

    test "a parked delivery offers reprocess", %{conn: conn, user: user} do
      sub = seed_subscription!(create_connection!(user), "widget.updated", ~s|error("boom")|)
      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      {:ok, _view, html} = live(conn, show_path(single_delivery()))

      assert html =~ "phx-click=\"reprocess\""
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp log_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp show_path(%{id: id}), do: "#{@index_path}/#{id}"

  defp reload(%{id: id}), do: Ash.get!(EventDelivery, id, authorize?: false)

  defp single_delivery do
    [delivery] = EventDelivery |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false)
    delivery
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

  defp create_subscription!(dest, event_type, transform_source \\ "-- noop") do
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

  # Plant a subscription whose transform raises at dispatch, past the save-time
  # smoke gate (it rejects a script that errors on the producer's example/1).
  # These reprocess-UI tests need a parked delivery to act on.
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

  defp fix_transform!(sub, script) do
    sub
    |> Ash.Changeset.for_update(:update, %{transform_source: script}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end
end
