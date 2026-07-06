defmodule Example.InboundTestSupport.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Example.InboundTestSupport.Exploder
  end
end

defmodule Example.InboundTestSupport.TestNotifier do
  @moduledoc false
  # Forwards Ash notifications to a registered test pid, so a test can assert that a
  # host action applied via a command actually fans out its notification
  # post-commit (the fenced apply runs inside a manual transaction, so the core
  # must collect + emit notifications itself).
  use Ash.Notifier

  @pid_key {__MODULE__, :pid}

  def register(pid), do: :persistent_term.put(@pid_key, pid)
  def unregister, do: :persistent_term.erase(@pid_key)

  @impl true
  def notify(%Ash.Notifier.Notification{} = notification) do
    case :persistent_term.get(@pid_key, nil) do
      nil -> :ok
      pid -> send(pid, {:command_notified, notification.resource, notification.action.name})
    end

    :ok
  end
end

defmodule Example.InboundTestSupport.Exploder do
  @moduledoc false
  # A test-only resource mapped to the existing `products` table. `:explode` raises
  # a `DBConnection.ConnectionError` (the canonical *transient* infra failure the
  # classifier must route to retry/dead-letter); `:touch` is a normal action with a
  # notifier attached, to prove notifications fan out when applied via a command.
  # Sharing the table means no extra migration.
  use Ash.Resource,
    domain: Example.InboundTestSupport.Domain,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Example.InboundTestSupport.TestNotifier]

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

    update :touch do
      accept [:partner_ref]
      require_atomic? false
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

defmodule Example.InboundTestSupport.TouchHandler do
  @moduledoc false
  use AshIntegration.Inbound.Declare.Handler

  @impl true
  def build_input(%{"id" => id, "ref" => ref}, ctx) do
    case Ash.get(Example.InboundTestSupport.Exploder, id, authorize?: false) do
      {:ok, record} ->
        {:ok, Ash.Changeset.for_update(record, :touch, %{partner_ref: ref}, actor: ctx.actor)}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def example, do: %{"id" => "00000000-0000-0000-0000-000000000000", "ref" => "TOUCHED"}
end
