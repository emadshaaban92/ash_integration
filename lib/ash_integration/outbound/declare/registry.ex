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

  @cache_key {__MODULE__, :snapshot}

  @doc """
  The `Producer` module for `event_type` (the module that captures + projects it).
  All resources declaring the type must name the same producer — checked by
  `verify!/1` — so the first mention is canonical. Returns `nil` if unknown.

  The no-arg form is an **O(1) map lookup** off the cached snapshot, not a domain
  scan; pass an explicit resource list (tests) to derive it uncached.
  """
  def producer_for(event_type), do: Map.get(cached().producers, event_type)

  def producer_for(event_type, resources) do
    Enum.find_value(build_triggers(resources), fn {_key, triggers} ->
      Enum.find_value(triggers, fn t -> if t.event_type == event_type, do: t.producer end)
    end)
  end

  @doc "`{resource, action} => [trigger]` — the change-capture side of the registry."
  def triggers, do: cached().triggers
  def triggers(resources), do: build_triggers(resources)

  @doc """
  `event_type => %{versions: [version], producers: [{resource, action}]}` — the
  derived catalog the form and dispatcher read. `versions` is the sorted union of
  every declaration's supported version numbers.

  Does **not** run `verify!/1`: the producer-consistency invariant is a code-level
  check run once at boot (`AshIntegration.Supervisor`), so re-verifying on every
  catalog read — which happens on each subscription create/update — would be
  wasted work.
  """
  def catalog, do: cached().catalog
  def catalog(resources), do: build_catalog(resources)

  # ── Boot-built cache (the DSL is compile-time, so the derived registry is
  # immutable for the running system). `catalog/0` / `triggers/0` / `producer_for/1`
  # rebuilt from a full domain scan on every dispatch batch, subscription write, and
  # LiveView render; instead we compute the snapshot once and read it from
  # `:persistent_term`. ──────────────────────────────────────────────────────────

  @doc """
  Build the derived snapshot and store it in `:persistent_term`. Called once at
  boot (`AshIntegration.Supervisor`); idempotent, safe to re-run after a hot
  upgrade.
  """
  def warm, do: build_and_store(source_resources())

  @doc "Drop the cached snapshot (next read rebuilds). For tests/hot-reload."
  def reset_cache, do: :persistent_term.erase(@cache_key)

  @doc false
  # The full derived snapshot: the two views plus an `event_type => producer` map
  # for O(1) `producer_for/1`.
  def build(resources \\ source_resources()) do
    triggers = build_triggers(resources)

    %{
      triggers: triggers,
      catalog: build_catalog(resources),
      producers: producers_from_triggers(triggers)
    }
  end

  defp cached do
    case :persistent_term.get(@cache_key, nil) do
      nil -> build_and_store(source_resources())
      snapshot -> snapshot
    end
  end

  defp build_and_store(resources) do
    snapshot = build(resources)

    # Only `put` when the value actually changes, so a lazy-fallback build that
    # races `warm/0` doesn't trigger persistent_term's global heap-scan a second
    # time (mirrors Dispatch.Supervisor.put_config/2).
    case :persistent_term.get(@cache_key, :__unset__) do
      ^snapshot -> :ok
      _ -> :persistent_term.put(@cache_key, snapshot)
    end

    snapshot
  end

  defp producers_from_triggers(triggers) do
    for {_key, ts} <- triggers, t <- ts, into: %{}, do: {t.event_type, t.producer}
  end

  defp build_triggers(resources) do
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

  defp build_catalog(resources) do
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
        [producer] -> verify_callbacks!(type, producer)
        many -> raise conflicting_producers_error(type, many)
      end
    end)
  end

  # Every required producer callback must be exported, asserted at boot.
  # `produce/3` and `event_key/2` run on the host's business-write critical path
  # (capture), and `project/3` decides fan-out — a missing one compiles fine but
  # crashes that write (or silently fails to deliver) at runtime. `example/1`
  # backs the preview/test surface. Failing loudly here turns a latent runtime
  # crash into a dev/CI boot error.
  @required_callbacks [produce: 3, event_key: 2, project: 3, example: 1]

  defp verify_callbacks!(type, producer) do
    Code.ensure_loaded(producer)

    missing =
      for {fun, arity} <- @required_callbacks,
          not function_exported?(producer, fun, arity),
          do: "#{fun}/#{arity}"

    unless missing == [] do
      raise """
      Event type #{inspect(type)} is produced by #{inspect(producer)}, which is \
      missing required callback(s): #{Enum.join(missing, ", ")}.

      A `Producer` must implement all of produce/3, event_key/2, project/3, and \
      example/1 (`use AshIntegration.Outbound.Declare.Producer`). produce/3 and \
      event_key/2 run during capture on the source action's critical path; project/3 \
      decides who receives the event (omission is never "deliver"); example/1 backs \
      the preview/test surface.
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
  # Cap on the number of orphans logged individually before collapsing the rest
  # into one summary line — a misconfigured environment could orphan thousands of
  # subscriptions, and one Logger line each would flood the boot log.
  @orphan_log_limit 20

  def warn_orphaned_subscriptions(resources \\ source_resources()) do
    catalog = catalog(resources)

    orphans =
      AshIntegration.subscription_resource()
      |> Ash.Query.new()
      # Stream in pages so a large subscription table is never loaded whole into
      # memory at boot.
      |> Ash.stream!(batch_size: 500, authorize?: false)
      |> Stream.filter(fn sub -> not known?(catalog, sub.event_type, sub.version) end)
      |> Enum.to_list()

    log_orphans(orphans)
    orphans
  rescue
    e ->
      Logger.warning(
        "AshIntegration: could not verify subscriptions against the event catalog: " <>
          Exception.message(e)
      )

      []
  end

  defp log_orphans([]), do: :ok

  defp log_orphans(orphans) do
    Enum.each(Enum.take(orphans, @orphan_log_limit), fn sub ->
      Logger.warning(
        "AshIntegration: subscription #{sub.id} references unknown event " <>
          "\"#{sub.event_type}\" v#{sub.version} — it will never match a dispatch. " <>
          "Fix its event_type/version or remove it."
      )
    end)

    extra = length(orphans) - @orphan_log_limit

    if extra > 0 do
      Logger.warning(
        "AshIntegration: …and #{extra} more orphaned subscription(s) " <>
          "(per-orphan logging capped at #{@orphan_log_limit})."
      )
    end

    :ok
  end

  defp known?(catalog, event_type, version) do
    case Map.fetch(catalog, event_type) do
      {:ok, %{versions: versions}} -> version in versions
      :error -> false
    end
  end
end
