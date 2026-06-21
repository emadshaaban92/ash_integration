defmodule AshIntegration.Inbound.Declare.Registry do
  @moduledoc """
  The derived command catalog: `%{canonical_command_type => %Registration{}}`.

  Unlike the outbound event registry (a *union* — many resources may contribute
  one event type), a command type has **exactly one** executor, so the registry
  enforces **uniqueness**: `verify!/0` raises at boot on any post-normalization
  duplicate across all scanned resources. The DSL is compile-time, so the derived
  map is immutable for the running system — `warm/0` builds it once into
  `:persistent_term` and every hot-path lookup is an O(1) map read.

  The map *is* the core's routing input (`Inbound.Execute`): the DSL + registry
  are one producer of it; tests hand the core a literal; a future host that wants
  no DSL passes its own. The dependency arrow points one way (DSL → data → core).
  """

  alias AshIntegration.Inbound.Declare.Info
  alias AshIntegration.Inbound.Declare.Registration

  @cache_key {__MODULE__, :routing}

  @doc """
  Resources carrying the `inbound_commands` extension, from the configured
  `command_domains`.
  """
  def command_resources do
    AshIntegration.command_domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&Info.commands?/1)
  end

  @doc """
  The routing map (`canonical_type => %Registration{}`). An O(1) read off the
  cached snapshot, lazily built (and cached) on first read if `warm/0` hasn't run.
  """
  def routing, do: cached()

  @doc "The `%Registration{}` for a canonical command type, or nil."
  def registration(command_type), do: Map.get(cached(), command_type)

  @doc "Build the routing map for an explicit resource list (uncached; tests)."
  def build(resources \\ command_resources()) do
    for resource <- resources,
        command <- Info.commands(resource),
        into: %{} do
      type = Info.command_type(command)

      {type,
       %Registration{
         command_type: type,
         resource: resource,
         action: Info.action(command),
         handler: Info.handler(command)
       }}
    end
  end

  @doc """
  Build the routing snapshot and store it in `:persistent_term`. Called once at
  boot (`AshIntegration.Supervisor`); idempotent, safe to re-run after a hot
  upgrade.
  """
  def warm, do: build_and_store(command_resources())

  @doc "Drop the cached snapshot (next read rebuilds). For tests/hot-reload."
  def reset_cache, do: :persistent_term.erase(@cache_key)

  defp cached do
    case :persistent_term.get(@cache_key, nil) do
      nil -> build_and_store(command_resources())
      snapshot -> snapshot
    end
  end

  defp build_and_store(resources) do
    snapshot = build(resources)

    case :persistent_term.get(@cache_key, :__unset__) do
      ^snapshot -> :ok
      _ -> :persistent_term.put(@cache_key, snapshot)
    end

    snapshot
  end

  @doc """
  Verify the catalog at boot: global uniqueness (no post-normalization duplicate
  command type across resources) and that every handler exports the required
  callbacks. Raises on violation; returns `:ok` otherwise.
  """
  def verify!(resources \\ command_resources()) do
    verify_uniqueness!(resources)
    verify_handlers!(resources)
    :ok
  end

  # A command type with two executors is ambiguous routing of an instruction — a
  # correctness bug. Surfaces in dev/CI, so it raises at boot.
  defp verify_uniqueness!(resources) do
    by_type =
      for resource <- resources, command <- Info.commands(resource) do
        {Info.command_type(command), resource}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.each(by_type, fn {type, declaring} ->
      case Enum.uniq(declaring) do
        [_one] -> :ok
        many -> raise duplicate_command_error(type, many)
      end
    end)
  end

  # `build_input/2` and `example/0` are required; `partition_key/1` is optional.
  @required_callbacks [build_input: 2, example: 0]

  defp verify_handlers!(resources) do
    for resource <- resources, command <- Info.commands(resource) do
      handler = Info.handler(command)
      Code.ensure_loaded(handler)

      missing =
        for {fun, arity} <- @required_callbacks,
            not function_exported?(handler, fun, arity),
            do: "#{fun}/#{arity}"

      unless missing == [] do
        raise """
        Command type #{inspect(Info.command_type(command))} (on #{inspect(resource)}) is \
        handled by #{inspect(handler)}, which is missing required callback(s): \
        #{Enum.join(missing, ", ")}.

        A Handler must implement build_input/2 and example/0 \
        (`use AshIntegration.Inbound.Declare.Handler`); partition_key/1 is optional.
        """
      end
    end

    :ok
  end

  defp duplicate_command_error(type, resources) do
    """
    Command type #{inspect(type)} is declared on more than one resource: \
    #{Enum.map_join(resources, ", ", &inspect/1)}. A command has exactly one \
    executor — declare it on a single resource (post-normalization, so \
    "Confirm_Order" and "confirm_order" collide).
    """
  end
end
