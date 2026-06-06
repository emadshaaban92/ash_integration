# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is also run by `mix setup` and `mix ecto.setup`.
#
# Seeds the **event-first** outbound model: source records (Widgets + StockItems)
# plus a Destination with Subscriptions on the event types they contribute.

alias Example.Accounts.User
alias Example.Catalog.{StockItem, Widget}
alias Example.Outbound.{Connection, Subscription}

# Default user (owns the destination; the actor for authorized source reads).
user =
  User
  |> Ash.Changeset.for_create(
    :register_with_password,
    %{email: "user@example.com", password: "password123!", password_confirmation: "password123!"},
    authorize?: false
  )
  |> Ash.create()
  |> case do
    {:ok, user} ->
      IO.puts("Created user: #{user.email}")
      user

    {:error, _} ->
      IO.puts("User user@example.com already exists, skipping")
      Ash.read_first!(User, authorize?: false)
  end

# Only seed the demo connection/subscriptions on a fresh database.
if Connection |> Ash.read!(authorize?: false) |> Enum.empty?() do
  # Source records — Widgets contribute `widget.updated` and `stock.changed`;
  # StockItems contribute `stock.changed` (keyed on their parent widget).
  widgets =
    for {name, stock} <- [
          {"Wireless Keyboard", 25},
          {"USB-C Monitor", 12},
          {"Ergonomic Mouse", 40}
        ] do
      widget =
        Widget
        |> Ash.Changeset.for_create(:create, %{name: name, stock: stock}, actor: user)
        |> Ash.create!(actor: user)

      IO.puts("Created widget: #{widget.name}")
      widget
    end

  for w <- widgets do
    StockItem
    |> Ash.Changeset.for_create(:create, %{widget_id: w.id, quantity: w.stock}, actor: user)
    |> Ash.create!(actor: user)
  end

  # Connection — transport + auth, owns the subscriptions below.
  connection =
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example Webhook",
        owner_id: user.id,
        transport_config: %{
          type: :http,
          base_url: "https://example.com",
          auth: %{type: "none"},
          headers: %{"content-type" => "application/json"},
          timeout_ms: 30_000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

  IO.puts("Created connection: #{connection.name}")

  # Subscriptions — one per event type the sources produce. Each carries its own
  # route (path + method) joined onto the connection's base URL, via the
  # transport-tagged route_config union. The transform mutates a pre-seeded,
  # transport-shaped `result` (body/headers/routing); `nil` is a no-op that sends
  # the resolved defaults.
  widget_script = """
  -- Customize delivery: send a trimmed body and tag the request with the widget id.
  result.body = {
    id = event.data.id,
    name = event.data.name,
    stock = event.data.stock,
  }
  result.headers["x-widget-id"] = event.data.id
  """

  for {event_type, script, path, method} <- [
        # A real transform: reshape the body + add a header.
        {"widget.updated", widget_script, "/widgets", :patch},
        # No script (nil): a no-op that sends `event.data` as the body with the
        # default wire headers — the common case.
        {"stock.changed", nil, "/stock", :post}
      ] do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: connection.id,
        event_type: event_type,
        version: 1,
        transform_source: script,
        route_config: %{type: :http, path: path, method: method}
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    IO.puts("Created subscription: #{event_type}")
  end
else
  IO.puts("Connections already exist, skipping demo seed")
end

IO.puts("\n✓ Seed data ready!")
IO.puts("  Sign in with: user@example.com / password123!")
