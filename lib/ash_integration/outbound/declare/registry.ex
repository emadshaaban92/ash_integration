defmodule AshIntegration.Outbound.Declare.Registry do
  @moduledoc """
  The derived event-first catalog.

  An event type is not declared centrally — it is the **union** of every
  resource-level `event` declaration that names it. This module derives that
  union by scanning the configured `source_domains`, and exposes the two views
  the dispatcher and the form need:

    * `triggers/0` — `{resource, action} => [trigger]`, where each trigger is the
      `%{event_type, versions, producer}` that the `(resource, action)` contributes.
    * `catalog/0` — `event_type => %{versions, producers}`, the derived catalog.

  `verify!/0` checks cross-mention consistency: for each event type, all resource
  declarations must name the **same** producer module, and that module must
  implement the required `project/3` (the authorization hook). Both are code bugs
  that surface in dev/CI, so they **raise** at boot. It does not check that two
  producers return compatible event-key spaces — that is a trusted convention.

  All functions accept an explicit resource list (defaulting to
  `source_resources/0`) so the catalog can be derived for a subset in tests.
  """

  require Logger

  alias AshIntegration.Outbound.Declare.Source.Info

  @type trigger :: %{
          event_type: String.t(),
          versions: [pos_integer()],
          producer: module()
        }

  @doc """
  Resources carrying the source-trigger extension, enumerated from the
  configured `source_domains`.
  """
  def source_resources do
    AshIntegration.source_domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&Info.source?/1)
  end

  @doc """
  The `Producer` module for `event_type` (the module that captures + projects it).
  All resources declaring the type must name the same producer — checked by
  `verify!/1` — so the first mention is canonical. Returns `nil` if unknown.
  """
  def producer_for(event_type, resources \\ source_resources()) do
    Enum.find_value(triggers(resources), fn {_key, triggers} ->
      Enum.find_value(triggers, fn t -> if t.event_type == event_type, do: t.producer end)
    end)
  end

  @doc "`{resource, action} => [trigger]` — the change-capture side of the registry."
  def triggers(resources \\ source_resources()) do
    for resource <- resources,
        event <- Info.events(resource),
        action <- Info.actions(event),
        reduce: %{} do
      acc ->
        trigger = %{
          event_type: Info.event_type(event),
          versions: Info.versions(event),
          producer: Info.producer(event)
        }

        Map.update(acc, {resource, action}, [trigger], &(&1 ++ [trigger]))
    end
  end

  @doc """
  `event_type => %{versions: [version], producers: [{resource, action}]}` — the
  derived catalog the form and dispatcher read. `versions` is the sorted union of
  every declaration's supported version numbers.

  Does **not** run `verify!/1`: the producer-consistency invariant is a code-level
  check run once at boot (`AshIntegration.Supervisor`), so re-verifying on every
  catalog read — which happens on each subscription create/update — would be
  wasted work.
  """
  def catalog(resources \\ source_resources()) do
    for resource <- resources,
        event <- Info.events(resource),
        reduce: %{} do
      acc ->
        type = Info.event_type(event)
        versions = Info.versions(event)
        producers = Enum.map(Info.actions(event), &{resource, &1})

        Map.update(
          acc,
          type,
          %{versions: versions, producers: producers},
          fn existing ->
            %{
              versions: Enum.sort(Enum.uniq(existing.versions ++ versions)),
              producers: existing.producers ++ producers
            }
          end
        )
    end
  end

  @doc """
  Verify producer consistency: for each event type, all resource mentions name the
  same producer module, which must implement the required `project/3`. Raises on
  violation; returns `:ok` otherwise.
  """
  def verify!(resources \\ source_resources()) do
    verify_producers!(resources)
    :ok
  end

  # Producer-level invariants: for each event type, all resource mentions must
  # name the SAME producer module, and that module must implement the required
  # `project/3` (the authorization hook — its absence would let a private event
  # broadcast by omission). Both are code bugs that surface in dev/CI, so they
  # raise at boot (`AshIntegration.Supervisor`).
  defp verify_producers!(resources) do
    by_type =
      for resource <- resources, event <- Info.events(resource) do
        {Info.event_type(event), Info.producer(event)}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.each(by_type, fn {type, producers} ->
      case Enum.uniq(producers) do
        [producer] -> verify_project_required!(type, producer)
        many -> raise conflicting_producers_error(type, many)
      end
    end)
  end

  defp verify_project_required!(type, producer) do
    Code.ensure_loaded(producer)

    unless function_exported?(producer, :project, 3) do
      raise """
      Event type #{inspect(type)} is produced by #{inspect(producer)}, which does not \
      implement the required `project/3` callback. Every event type must state who \
      receives it (even "everyone" — a one-line `def project(events, _subs, _ctx), do: \
      Map.new(events, &{&1.id, :deliver})`); omission is not allowed, so a private \
      event can't broadcast by mistake.
      """
    end
  end

  defp conflicting_producers_error(type, producers) do
    """
    Conflicting producers for event #{inspect(type)}. Every resource declaring an \
    event type must name the SAME `AshIntegration.Outbound.Declare.Producer` module, \
    but found: #{Enum.map_join(producers, ", ", &inspect/1)}.
    """
  end

  @doc """
  Warn about persisted subscriptions whose `(event_type, version)` is no longer in
  the derived catalog — they will never match a dispatch.

  Unlike `verify!/0`, this is a **data** problem, not a **code** one: a schema
  conflict is a bug that shows up in dev/CI and must be fixed, so `verify!`
  raises; an orphaned subscription is operational drift (a renamed/removed event,
  an un-migrated environment) and must **not** crash boot — so this only logs.
  Returns the orphaned subscriptions. Resilient: if the catalog or the DB can't
  be read at boot (e.g. migrations not yet run), it warns once and returns `[]`.
  """
  def warn_orphaned_subscriptions(resources \\ source_resources()) do
    catalog = catalog(resources)

    AshIntegration.subscription_resource()
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn sub -> not known?(catalog, sub.event_type, sub.version) end)
    |> tap(fn orphans ->
      Enum.each(orphans, fn sub ->
        Logger.warning(
          "AshIntegration: subscription #{sub.id} references unknown event " <>
            "\"#{sub.event_type}\" v#{sub.version} — it will never match a dispatch. " <>
            "Fix its event_type/version or remove it."
        )
      end)
    end)
  rescue
    e ->
      Logger.warning(
        "AshIntegration: could not verify subscriptions against the event catalog: " <>
          Exception.message(e)
      )

      []
  end

  defp known?(catalog, event_type, version) do
    case Map.fetch(catalog, event_type) do
      {:ok, %{versions: versions}} -> version in versions
      :error -> false
    end
  end
end
