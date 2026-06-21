defmodule Example.InboundTestSupport.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Example.InboundTestSupport.Exploder
  end
end

defmodule Example.InboundTestSupport.Exploder do
  @moduledoc false
  # A test-only resource mapped to the existing `products` table whose `:explode`
  # action raises a `DBConnection.ConnectionError` — the canonical *transient*
  # (infrastructure) failure the classifier must route to retry/dead-letter rather
  # than to a terminal `:failed`. Sharing the table means no extra migration.
  use Ash.Resource,
    domain: Example.InboundTestSupport.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "products"
    repo Example.Repo
  end

  actions do
    defaults [:read]

    update :explode do
      accept []
      require_atomic? false

      # The raise must happen at action-RUN time (inside the apply transaction),
      # not at changeset-build time — so register it as a before_action hook rather
      # than raising in the change body (which runs while `build_input` builds the
      # changeset, before execution).
      change fn changeset, _ctx ->
        Ash.Changeset.before_action(changeset, fn _cs ->
          raise DBConnection.ConnectionError, "simulated infra failure"
        end)
      end
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :name, :string, public?: true
    attribute :sku, :string, public?: true
    attribute :partner_ref, :string, public?: true
  end
end

defmodule Example.InboundTestSupport.ExplodeHandler do
  @moduledoc false
  use AshIntegration.Inbound.Declare.Handler

  @impl true
  def build_input(%{"id" => id}, ctx) do
    case Ash.get(Example.InboundTestSupport.Exploder, id, authorize?: false) do
      {:ok, record} ->
        {:ok, Ash.Changeset.for_update(record, :explode, %{}, actor: ctx.actor)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def example, do: %{"id" => "00000000-0000-0000-0000-000000000000"}
end
