defmodule Example.Outbound.EventTransformerTest do
  @moduledoc """
  Compile-time regression tests for `AshIntegration.Outbound.Capture.Event.Transformer`
  (item 5). These prove the injector composes with host-authored DSL instead of
  colliding with it:

    * a host that explicitly defines `read :read` (or `destroy :destroy`) must NOT
      get a second `:read`/`:destroy` injected via `defaults` (which would be a
      "Got duplicate action" DSL error pointing at library code the host never wrote);
    * a host that defines one code-interface entry must not have the whole library
      set re-added on top (a duplicate `define`);
    * a host that sets its own `migration_defaults` must keep them — the library's
      `id` default is MERGED in, not replaced.

  The modules below simply compiling (this test file loads) is itself the assertion
  for the collision cases; the tests then verify the resulting definitions.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshPostgres.DataLayer.Info, as: PgInfo

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Example.Outbound.EventTransformerTest.ExplicitReadEvent
      resource Example.Outbound.EventTransformerTest.CustomInterfaceEvent
      resource Example.Outbound.EventTransformerTest.CustomMigrationDefaultsEvent
    end
  end

  defmodule ExplicitReadEvent do
    @moduledoc false
    use Ash.Resource,
      domain: Example.Outbound.EventTransformerTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshIntegration.Outbound.Capture.Event],
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table "et_explicit_read_events"
      repo Example.Repo
    end

    # The host defines its OWN read action of the default name. Before the fix, the
    # transformer still injected `defaults [:read]`, producing two `:read` actions.
    actions do
      read :read do
        primary? true
      end
    end

    policies do
      policy always() do
        authorize_if always()
      end
    end
  end

  defmodule CustomInterfaceEvent do
    @moduledoc false
    use Ash.Resource,
      domain: Example.Outbound.EventTransformerTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshIntegration.Outbound.Capture.Event],
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table "et_custom_interface_events"
      repo Example.Repo
    end

    # The host pre-defines ONE code interface (:destroy). Before the fix, the
    # transformer's `if any :create? -> skip all else add all` sentinel re-added the
    # whole set (including a second :destroy).
    code_interface do
      define :destroy, action: :destroy
    end

    policies do
      policy always() do
        authorize_if always()
      end
    end
  end

  defmodule CustomMigrationDefaultsEvent do
    @moduledoc false
    use Ash.Resource,
      domain: Example.Outbound.EventTransformerTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshIntegration.Outbound.Capture.Event],
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table "et_custom_migration_defaults_events"
      repo Example.Repo
      # The host sets its own migration default. Before the fix, the transformer's
      # `set_option(:migration_defaults, id: ...)` REPLACED this whole keyword.
      migration_defaults note: "\"host\""
    end

    attributes do
      attribute :note, :string, public?: true
    end

    policies do
      policy always() do
        authorize_if always()
      end
    end
  end

  test "a host-defined `read :read` does not collide with the injected default read" do
    reads = ResourceInfo.actions(ExplicitReadEvent) |> Enum.filter(&(&1.name == :read))
    assert length(reads) == 1, "expected exactly one :read action, got #{length(reads)}"
    # The library still injects the other actions it owns.
    assert ResourceInfo.action(ExplicitReadEvent, :dispatch)
    assert ResourceInfo.action(ExplicitReadEvent, :create)
  end

  test "a host-defined code interface is not clobbered, and the rest are still added" do
    names = CustomInterfaceEvent |> ResourceInfo.interfaces() |> Enum.map(& &1.name)

    # The host's :destroy define survives exactly once...
    assert Enum.count(names, &(&1 == :destroy)) == 1
    # ...and the library still adds the interfaces the host didn't define.
    for name <- [:create, :read_all, :reset_dispatch] do
      assert name in names, "expected the library to add the #{name} code interface"
    end
  end

  test "host migration_defaults are merged with the library's id default, not replaced" do
    defaults = PgInfo.migration_defaults(CustomMigrationDefaultsEvent)

    assert Keyword.get(defaults, :note) == "\"host\"", "host migration default must survive"
    assert Keyword.get(defaults, :id) =~ "uuidv7()", "library id default must be merged in"
  end
end
