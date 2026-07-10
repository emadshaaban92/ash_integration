defmodule Example.Outbound.AuthzHardeningTest do
  @moduledoc """
  Authorization hardening for the dashboard's privileged operator actions and the
  injected state-machine resources.

  Two layers are covered:

    * The bulk "reprocess parked" LiveView handler, which runs the Reprocessor under
      system authority. It must resolve the connection AS THE ACTOR (fail closed on
      an unreadable/absent connection) before touching anything — a LiveView event is
      client-triggerable even when the button is hidden, so the server is the only
      real gate. A permitted actor still succeeds end-to-end.

    * The defense-in-depth policy injected onto Event/EventDelivery: the internal
      state-machine actions (`:deliver`/`:park`/`:record_failure`/`:reset_dispatch`)
      are forbidden for any actor-bearing call, while the pipeline's own
      `authorize?: false` calls sail through untouched.
  """
  use ExampleWeb.ConnCase, async: false

  require Ash.Query
  import Phoenix.LiveViewTest
  import Example.DataCase, only: [build_delivery!: 2, drain_dispatch!: 0]
  import Example.IntegrationHelpers, only: [create_user!: 0]

  alias AshIntegration.Outbound.Delivery.Reprocessor
  alias Example.Catalog.Widget
  alias Example.Outbound.{Connection, Event, EventDelivery, Subscription}

  @deliveries_path "/integrations/deliveries"

  setup %{conn: conn} do
    user = create_user!()
    connection = create_connection!(user)
    %{conn: log_in(conn, user), user: user, connection: connection}
  end

  describe "bulk reprocess-parked (LiveView)" do
    test "a permitted actor reprocesses the connection's parked deliveries", ctx do
      %{conn: conn, connection: dest} = ctx
      sub = seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      parked = single_delivery()
      assert parked.state == :parked

      # Fix the build, then drive the operator's bulk-reprocess button.
      fix_transform!(sub, "-- noop")

      {:ok, view, _html} = live(conn, "#{@deliveries_path}?connection=#{dest.id}")
      html = view |> element("button[phx-click=reprocess-parked]") |> render_click()

      assert html =~ "Reprocessed 1 parked delivery(ies)"
      assert reload(parked).state == :pending
    end

    test "fails closed when the scoped connection is not readable — no reprocess", ctx do
      %{conn: conn, connection: dest} = ctx
      # A real parked delivery under a readable connection: it must stay untouched.
      seed_subscription!(dest, "widget.updated", ~s|error("boom")|)
      create_widget!(%{name: "w", stock: 1})
      drain_dispatch!()

      parked = single_delivery()
      assert parked.state == :parked

      # The URL filter points at a connection that does not resolve for the actor.
      # The button is hidden (parked_count is 0 for it), but the event is still
      # client-triggerable — the server gate must refuse.
      bogus = Ash.UUID.generate()
      {:ok, view, _html} = live(conn, "#{@deliveries_path}?connection=#{bogus}")

      html = render_click(view, "reprocess-parked", %{})

      assert html =~ "Not authorized to reprocess deliveries"
      # The real parked delivery was never reprocessed.
      assert reload(parked).state == :parked
    end
  end

  describe "state-machine actions are system-authority only (injected policy)" do
    setup ctx do
      sub = create_subscription!(ctx.connection, "widget.updated")
      delivery = build_delivery!(sub, %{state: :scheduled})
      %{delivery: delivery, event: Ash.get!(Event, delivery.event_id, authorize?: false)}
    end

    for action <- [:deliver, :park, :record_failure] do
      test "EventDelivery.#{action} is forbidden for an actor-bearing caller", ctx do
        assert {:error, %Ash.Error.Forbidden{}} =
                 ctx.delivery
                 |> Ash.Changeset.for_update(unquote(action), params(unquote(action)),
                   actor: ctx.user
                 )
                 |> Ash.update(actor: ctx.user)
      end
    end

    test "the pipeline's authorize?: false transitions still pass", ctx do
      assert {:ok, parked} =
               ctx.delivery
               |> Ash.Changeset.for_update(:park, %{last_error: "boom"}, authorize?: false)
               |> Ash.update(authorize?: false)

      assert parked.state == :parked
    end

    test "Event.reset_dispatch is forbidden for an actor but allowed under system authority",
         ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.event
               |> Ash.Changeset.for_update(:reset_dispatch, %{}, actor: ctx.user)
               |> Ash.update(actor: ctx.user)

      assert {:ok, _event} =
               ctx.event
               |> Ash.Changeset.for_update(:reset_dispatch, %{}, authorize?: false)
               |> Ash.update(authorize?: false)
    end

    test "Event.expire_dispatch is forbidden for an actor but allowed under system authority",
         ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.event
               |> Ash.Changeset.for_update(:expire_dispatch, %{}, actor: ctx.user)
               |> Ash.update(actor: ctx.user)

      assert {:ok, event} =
               ctx.event
               |> Ash.Changeset.for_update(:expire_dispatch, %{}, authorize?: false)
               |> Ash.update(authorize?: false)

      assert event.dispatch_terminal_reason == :expired
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp params(:record_failure), do: %{last_error: "x"}
  defp params(_), do: %{}

  defp log_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

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

  defp seed_subscription!(dest, event_type, transform_source) do
    Ash.Seed.seed!(Subscription, %{
      connection_id: dest.id,
      event_type: event_type,
      version: 1,
      transform_source: transform_source,
      active: true,
      suspended: false
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
