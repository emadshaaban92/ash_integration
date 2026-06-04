defmodule AshIntegration.Outbound.Capture.PublishEvent do
  @moduledoc false
  # Synchronous change-capture hook.
  #
  # Injected resource-locally by `AshIntegration.Outbound.Declare.Source.Transformer` onto
  # every source resource, on `[:create, :update, :destroy]`. It runs **in the
  # source transaction**: for the changed `(resource, action)` it resolves the
  # triggered event types, finds the **subscribed** versions (only versions with ≥1
  # active subscription are materialized — capture is O(subscribed versions)), runs
  # the producer's `produce/3` **once per subscribed version** over the in-memory
  # `{changeset, record}` pairs, and creates one immutable `Event` per
  # `(change, type, subscribed version)`. The Event table IS the transactional
  # outbox; a dispatch job (the relay) then fans each Event out.
  #
  # `produce` runs under producer/system authority (no per-actor read) — capture
  # is point-in-time; authorization moves to the producer's `project/3` at
  # dispatch.
  #
  # ## Capture-failure blast radius (IMPORTANT)
  #
  # Because capture runs in the source transaction, a failure here — a raising
  # `produce`/`event_key`, or a failed bulk `Event` insert — **rolls back the
  # host's business action**. This is deliberate: it preserves the transactional
  # outbox (no committed change without its event, no event without its change).
  # The cost is coupling — a producer bug can block a business write.
  #
  # An event can opt OUT of that coupling per-declaration with `capture_isolation?
  # true`: a `produce`/`event_key` failure for THAT event is caught, logged, and
  # surfaced on `[:ash_integration, :capture, :isolated_failure]` telemetry, and the
  # event is **dropped** (the business action still commits). Use it for
  # non-critical events where availability beats outbox completeness. The shared
  # bulk insert is still all-or-nothing (an infra-level DB failure is not isolable
  # per event).
  use Ash.Resource.Change

  require Ash.Tracer
  require Ash.Query
  require Logger

  alias AshIntegration.Outbound.Declare.Source.Info

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def after_batch([], _opts, _context), do: :ok

  def after_batch(changesets_and_results, _opts, context) do
    {changeset, _} = List.first(changesets_and_results)
    action = changeset.action

    case triggers_for(changeset.resource, action.name) do
      [] ->
        :ok

      triggers ->
        meta = %{
          source_resource: Info.source_resource(changeset.resource),
          action_string: to_string(action.name)
        }

        ctx = %{action: action.name, actor: context.actor}

        Ash.Tracer.span :custom, "Outbound.PublishEvent", changeset.context[:private][:tracer] do
          triggers
          |> Enum.flat_map(&capture(&1, changesets_and_results, ctx, meta))
          |> create_and_enqueue()
        end

        :ok
    end
  end

  # The event types this resource contributes for `action` (resource-local, so no
  # global registry scan): each yields `%{event_type, producer, versions}`.
  defp triggers_for(resource, action) do
    for event <- Info.events(resource), action in Info.actions(event) do
      %{
        event_type: Info.event_type(event),
        producer: Info.producer(event),
        versions: Info.versions(event),
        capture_isolation?: Info.capture_isolation?(event)
      }
    end
  end

  # One trigger → Event attrs for each subscribed version × produced data. When the
  # event opts into `capture_isolation?`, a raising produce/event_key is caught,
  # logged, and the event dropped — the host action commits regardless.
  defp capture(%{capture_isolation?: true} = trigger, pairs, ctx, meta) do
    do_capture(trigger, pairs, ctx, meta)
  rescue
    exception ->
      Logger.error(
        "AshIntegration: isolated capture failure for event " <>
          "\"#{trigger.event_type}\" (#{inspect(trigger.producer)}) — event dropped, host " <>
          "action committed: #{Exception.message(exception)}"
      )

      :telemetry.execute(
        [:ash_integration, :capture, :isolated_failure],
        %{count: 1},
        %{event_type: trigger.event_type, producer: trigger.producer}
      )

      []
  end

  defp capture(trigger, pairs, ctx, meta), do: do_capture(trigger, pairs, ctx, meta)

  defp do_capture(%{event_type: type, producer: producer, versions: versions}, pairs, ctx, meta) do
    type
    |> subscribed_versions(versions)
    |> Enum.flat_map(fn version ->
      producer.produce(version, pairs, ctx)
      |> Enum.map(fn {record_id, data} ->
        %{
          event_type: type,
          version: version,
          event_key: resolve_key(producer, version, data),
          source_resource: meta.source_resource,
          source_resource_id: to_string(record_id),
          source_action: meta.action_string,
          data: data
        }
      end)
    end)
  end

  # Materialize only versions someone is actually listening to — one cheap query,
  # gated on both subscription and connection being `active`.
  defp subscribed_versions(_type, []), do: []

  defp subscribed_versions(type, candidate_versions) do
    AshIntegration.subscription_resource()
    |> Ash.Query.filter(
      event_type == ^type and version in ^candidate_versions and
        active == true and connection.active == true
    )
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.version)
    |> Enum.uniq()
  end

  # The event key must be value-stable per entity (host responsibility). It is the
  # (connection, event_key) ordering + coalescing lane AND the `event-key`
  # wire header, so `event_key/2` is contracted to return a **non-empty
  # `String.t()`** — and the callback is mandatory, so there is no excuse to return
  # nil. Anything else (nil, a blank string, a non-string term) is a producer code
  # bug: coercing it would crash (tuples/maps), fabricate garbage (a charlist list),
  # or collapse unrelated entities onto one lane (blank). So we **raise** rather than
  # invent a key — fail fast over silent corruption.
  defp resolve_key(producer, version, data) do
    case producer.event_key(version, data) do
      key when is_binary(key) ->
        if String.trim(key) == "", do: invalid_key!(producer, version, key), else: key

      other ->
        invalid_key!(producer, version, other)
    end
  end

  defp invalid_key!(producer, version, value) do
    raise ArgumentError, """
    #{inspect(producer)}.event_key/2 (v#{version}) must return a non-empty String.t(), \
    but returned: #{inspect(value)}.

    The event key is the (connection, event_key) ordering + coalescing lane and the \
    `event-key` wire header — it must be a stable, non-empty string. The callback is \
    required, so always return a real key (e.g. `to_string(id)`); nil/blank is not allowed.
    """
  end

  defp create_and_enqueue([]), do: :ok

  defp create_and_enqueue(attrs_list) do
    # Created in the source transaction (after_batch is pre-commit) — the
    # transactional-outbox guarantee: no Event without its source change, and
    # vice versa. One bulk insert for the whole change-batch's events (a bulk
    # source action can fan out many); it raises on failure, rolling back the
    # source txn.
    #
    # No per-event dispatch job: the Event table IS the outbox, so a second
    # durable record pointing back at it would be redundant. The dispatch relay
    # claims `dispatched_at IS NULL` rows directly on its poll interval — uniform
    # for same-node and cross-node capture alike, so there is nothing to nudge here.
    Ash.bulk_create!(attrs_list, AshIntegration.event_resource(), :create,
      return_records?: false,
      authorize?: false
    )

    :ok
  end
end
