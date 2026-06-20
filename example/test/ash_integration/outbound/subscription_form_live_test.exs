defmodule Example.Outbound.SubscriptionFormLiveTest do
  @moduledoc """
  LiveView coverage for the event-first subscription form's per-route config: the
  "Delivery route" card renders the right fields for the connection's transport,
  swaps reactively when the selected connection changes, and submission persists
  the correct `route_config` union. Also guards the connection-picker
  load (which must not silently empty out on the paginated `:index` read).
  """
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Example.Outbound.{Connection, Subscription}

  @new_path "/integrations/subscriptions/new"

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

  test "lists connections and renders HTTP route fields for an HTTP connection", %{
    conn: conn,
    user: user
  } do
    http = create_http_connection!(user)

    {:ok, _view, html} = live(conn, @new_path)

    # Regression: the connection picker must actually load (paginated :index read).
    assert html =~ http.name
    # HTTP route fields present; no Kafka topic field.
    assert html =~ ~s(name="form[route][method]")
    assert html =~ ~s(name="form[route][path]")
    refute html =~ ~s(name="form[route][topic]")
  end

  test "swaps to the Kafka topic field when a Kafka connection is selected", %{
    conn: conn,
    user: user
  } do
    create_http_connection!(user)
    kafka = create_kafka_connection!(user)

    {:ok, view, _html} = live(conn, @new_path)

    html =
      view
      |> form("#subscription-form", form: %{"connection_id" => kafka.id})
      |> render_change()

    assert html =~ ~s(name="form[route][topic]")
    refute html =~ ~s(name="form[route][method]")
  end

  test "creates an HTTP subscription with an http route_config", %{conn: conn, user: user} do
    http = create_http_connection!(user)

    {:ok, view, _html} = live(conn, @new_path)

    view
    |> form("#subscription-form",
      form: %{
        "connection_id" => http.id,
        "event_type" => "widget.updated",
        "version" => "1",
        "transform_source" => "function transform(event, defaults) return event end",
        "route" => %{"method" => "patch", "path" => "/widgets"}
      }
    )
    |> render_submit()

    assert [sub] = Ash.read!(Subscription, authorize?: false)
    assert sub.event_type == "widget.updated"
    assert %Ash.Union{type: :http, value: route} = sub.route_config
    assert route.path == "/widgets"
    assert route.method == :patch
  end

  test "creates a Kafka subscription with a kafka route_config", %{conn: conn, user: user} do
    kafka = create_kafka_connection!(user)

    {:ok, view, _html} = live(conn, @new_path)

    # Select the Kafka connection first so the form's route variant is :kafka.
    view
    |> form("#subscription-form", form: %{"connection_id" => kafka.id})
    |> render_change()

    view
    |> form("#subscription-form",
      form: %{
        "connection_id" => kafka.id,
        "event_type" => "stock.changed",
        "version" => "1",
        "transform_source" => "function transform(event, defaults) return event end",
        "route" => %{"topic" => "orders"}
      }
    )
    |> render_submit()

    assert [sub] = Ash.read!(Subscription, authorize?: false)
    assert %Ash.Union{type: :kafka, value: route} = sub.route_config
    assert route.topic == "orders"
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "form-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end

  defp create_http_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "HTTP-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "https://api.example.com",
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_kafka_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Kafka-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :kafka,
          brokers: ["localhost:9092"],
          topic: "default-topic",
          security: %{type: "none"}
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
