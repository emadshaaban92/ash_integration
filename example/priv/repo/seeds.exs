# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is also run by `mix setup` and `mix ecto.setup`.

alias Example.Accounts.User
alias Example.Catalog.Product
alias Example.Integration.OutboundIntegration

# Create a default user
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

# Create sample products
product_data = [
  {"Wireless Keyboard", "KB-001"},
  {"USB-C Monitor", "MON-002"},
  {"Ergonomic Mouse", "MS-003"}
]

for {name, sku} <- product_data do
  Product
  |> Ash.Changeset.for_create(:create, %{name: name, sku: sku}, authorize?: false)
  |> Ash.create()
  |> case do
    {:ok, _} -> IO.puts("Created product: #{name}")
    {:error, _} -> IO.puts("Product #{name} already exists, skipping")
  end
end

# Create a sample outbound integration
OutboundIntegration
|> Ash.Changeset.for_create(
  :create,
  %{
    name: "Example Webhook",
    resource: "product",
    actions: ["create", "update"],
    schema_version: 1,
    owner_id: user.id,
    transport: :http,
    transport_config: %{
      url: "https://httpbin.org/post",
      method: :post,
      headers: %{"content-type" => "application/json"},
      timeout_ms: 30_000
    },
    transform_script: ~S"""
    result = event
    """
  },
  authorize?: false
)
|> Ash.create()
|> case do
  {:ok, integration} -> IO.puts("Created integration: #{integration.name}")
  {:error, _} -> IO.puts("Integration already exists, skipping")
end

IO.puts("\n✓ Seed data ready!")
IO.puts("  Sign in with: user@example.com / password123!")
