defmodule Example.Outbound.DefaultSortTest do
  @moduledoc """
  The declared default sort, asserted on RESULTS against a real database.

  `Example.Outbound.DefaultSortDslTest` guards the DSL shape; this guards the
  observable effect — the rows the "Recent deliveries" / delivery-browser panes
  actually render. `id` is a DB-minted UUIDv7 (`uuidv7()`), so it is time-ordered
  and unique: insertion order IS ascending id order, and a correct `:index` /
  `:for_subscription` read hands back the newest row first.

  Also covers the pagination hazard behind the bug: `:index` and `:for_subscription`
  declare `keyset?: true, offset?: true`, and paging an unordered query can repeat or
  skip rows between pages — so an unsorted browser does not merely misorder rows, it
  can lose them.
  """
  use Example.DataCase, async: true

  import Example.IntegrationHelpers, only: [create_user!: 0]

  alias Example.Outbound.{Connection, EventDelivery, Subscription}

  setup do
    connection = create_connection!(create_user!())
    %{connection: connection, subscription: create_subscription!(connection, "widget.updated")}
  end

  describe ":for_subscription" do
    test "returns the newest delivery first", %{subscription: subscription} do
      inserted = insert_deliveries!(subscription, 5, :pending)

      ids =
        EventDelivery
        |> Ash.Query.for_read(:for_subscription, %{subscription_id: subscription.id},
          authorize?: false
        )
        |> Ash.read!(page: [limit: 10], authorize?: false)
        |> Map.fetch!(:results)
        |> Enum.map(& &1.id)

      assert ids == Enum.reverse(inserted),
             "expected newest-first (descending id); the pane must not omit the newest row"

      assert strictly_descending?(ids)
    end

    test "paginates without repeating or skipping rows", %{subscription: subscription} do
      inserted = insert_deliveries!(subscription, 5, :pending)

      assert paged_ids(:for_subscription, %{subscription_id: subscription.id}, 2) ==
               Enum.reverse(inserted)
    end
  end

  describe ":index" do
    test "returns the newest delivery first", %{subscription: subscription} do
      inserted = insert_deliveries!(subscription, 5, :pending)

      ids =
        EventDelivery
        |> Ash.Query.for_read(:index, %{}, authorize?: false)
        |> Ash.read!(page: [limit: 10], authorize?: false)
        |> Map.fetch!(:results)
        |> Enum.map(& &1.id)

      assert ids == Enum.reverse(inserted)
      assert strictly_descending?(ids)
    end

    test "paginates without repeating or skipping rows", %{subscription: subscription} do
      inserted = insert_deliveries!(subscription, 5, :pending)

      assert paged_ids(:index, %{}, 2) == Enum.reverse(inserted)
    end
  end

  # NOTE: unlike the two above, this one does not fail on the un-nested (dropped-sort)
  # shape. Ids are DB-minted in insertion order, so an UNSORTED scan of a small table
  # happens to come back ascending — indistinguishable from the correct `id: :asc`.
  # Its job is to pin the DIRECTION (parked replay is deliberately oldest-first, not
  # newest-first); the dropped-sort regression on `:parked` is caught by the DSL test.
  describe ":parked" do
    test "returns the oldest parked delivery first", %{
      connection: connection,
      subscription: subscription
    } do
      inserted = insert_deliveries!(subscription, 5, :parked)

      ids =
        EventDelivery
        |> Ash.Query.for_read(:parked, %{connection_id: connection.id}, authorize?: false)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert ids == inserted, "parked replay is oldest-first (ascending id) on purpose"
      assert strictly_ascending?(ids)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Returns the ids in insertion order, i.e. ASCENDING (the DB mints each UUIDv7).
  defp insert_deliveries!(subscription, count, state) do
    Enum.map(1..count, fn n ->
      build_delivery!(subscription, %{state: state, event_key: "k#{n}"}).id
    end)
  end

  # Walk every page of a paginated read and collect ids. Repeats or gaps here mean
  # rows are lost or duplicated across page boundaries.
  defp paged_ids(action, args, limit) do
    EventDelivery
    |> Ash.Query.for_read(action, args, authorize?: false)
    |> Ash.read!(page: [limit: limit], authorize?: false)
    |> collect_pages([])
  end

  defp collect_pages(page, acc) do
    acc = acc ++ Enum.map(page.results, & &1.id)

    case Ash.page(page, :next) do
      {:ok, %{results: []}} -> acc
      {:ok, next} -> collect_pages(next, acc)
      {:error, _} -> acc
    end
  end

  defp strictly_descending?(ids), do: ids == ids |> Enum.sort() |> Enum.reverse()
  defp strictly_ascending?(ids), do: ids == Enum.sort(ids)

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

  defp create_subscription!(connection, event_type) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: connection.id,
        event_type: event_type,
        version: 1,
        transform_source: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
