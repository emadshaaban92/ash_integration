defmodule Example.Outbound.SubscriptionIndexLiveTest do
  @moduledoc """
  Covers the `:deliveries` rename, the `last_delivered_at` aggregate, and the
  subscriptions index that consumes them — which previously blanked a populated
  list when the (then-undefined) aggregate failed to load.
  """
  use ExampleWeb.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import Example.DataCase

  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  @index_path "/integrations/subscriptions"

  setup %{conn: conn} do
    user = create_user!()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    %{conn: conn, user: user}
  end

  describe "relationships" do
    test "connection and subscription expose :deliveries, not :events" do
      refute Ash.Resource.Info.relationship(Subscription, :events),
             "subscription should no longer expose a misnamed :events relationship"

      refute Ash.Resource.Info.relationship(Connection, :events),
             "connection should no longer expose a misnamed :events relationship"

      assert Ash.Resource.Info.relationship(Subscription, :deliveries).destination ==
               EventDelivery

      assert Ash.Resource.Info.relationship(Connection, :deliveries).destination == EventDelivery
    end

    test "subscription.deliveries and connection.deliveries load EventDelivery rows", %{
      user: user
    } do
      connection = create_connection!(user)
      subscription = create_subscription!(connection, "widget.updated")
      delivery = build_delivery!(subscription, %{state: :delivered})

      loaded_sub =
        Subscription
        |> Ash.Query.filter(id == ^subscription.id)
        |> Ash.Query.load(:deliveries)
        |> Ash.read_one!(authorize?: false)

      assert [%EventDelivery{} = d] = loaded_sub.deliveries
      assert d.id == delivery.id

      loaded_conn =
        Connection
        |> Ash.Query.filter(id == ^connection.id)
        |> Ash.Query.load(:deliveries)
        |> Ash.read_one!(authorize?: false)

      assert [%EventDelivery{} = cd] = loaded_conn.deliveries
      assert cd.id == delivery.id
    end
  end

  describe "last_delivered_at aggregate" do
    test "is the max delivered_at over delivered deliveries only", %{user: user} do
      connection = create_connection!(user)
      subscription = create_subscription!(connection, "widget.updated")

      build_delivery!(subscription, %{state: :pending})
      delivered = build_delivery!(subscription, %{state: :delivered})

      loaded =
        Subscription
        |> Ash.Query.filter(id == ^subscription.id)
        |> Ash.Query.load(:last_delivered_at)
        |> Ash.read_one!(authorize?: false)

      assert loaded.last_delivered_at == delivered.delivered_at
    end

    test "is nil when the subscription has no delivered deliveries", %{user: user} do
      connection = create_connection!(user)
      subscription = create_subscription!(connection, "widget.updated")
      build_delivery!(subscription, %{state: :pending})

      loaded =
        Subscription
        |> Ash.Query.filter(id == ^subscription.id)
        |> Ash.Query.load(:last_delivered_at)
        |> Ash.read_one!(authorize?: false)

      assert is_nil(loaded.last_delivered_at)
    end
  end

  describe "index" do
    test "lists every subscription and renders the last delivery time", %{
      conn: conn,
      user: user
    } do
      connection = create_connection!(user)

      event_types = ["widget.updated", "stock.changed", "widget.scoped"]
      subs = Enum.map(event_types, &create_subscription!(connection, &1))

      [first | _] = subs
      delivered = build_delivery!(first, %{state: :delivered})

      {:ok, _view, html} = live(conn, @index_path)

      # The regression: a populated list must not collapse into the empty state.
      refute html =~ "No subscriptions yet"

      for event_type <- event_types do
        assert html =~ event_type
      end

      assert delivered.delivered_at
      assert html =~ format_datetime(delivered.delivered_at)
    end
  end

  describe "load-failure handling" do
    # A genuine load failure must crash, not be swallowed into an empty page.
    test "read_page! raises a genuine load failure instead of swallowing it", %{user: user} do
      assert_raise Ash.Error.Invalid, fn ->
        Subscription
        |> Ash.Query.load(:definitely_not_a_real_field)
        |> AshIntegration.Web.Outbound.Helpers.read_page!(
          actor: user,
          page: [limit: 20, offset: 0, count: true]
        )
      end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp format_datetime(dt), do: AshIntegration.Web.Outbound.Helpers.format_datetime(dt)

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "idx-#{System.unique_integer([:positive])}@x.com"},
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
        transform_source: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
