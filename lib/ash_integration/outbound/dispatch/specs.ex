defmodule AshIntegration.Outbound.Dispatch.Specs do
  @moduledoc false
  # Pure fan-out planning for the dispatch relay.
  #
  # Turns a claimed `(event_type, version)` batch of immutable Events + their shared
  # candidate subscriptions into a flat list of EventDelivery **specs** — each a
  # `%{attrs: create_attrs, coalesce?: bool}` already classified `:pending` /
  # `:parked` / `:cancelled`. This is the work that runs in the Broadway **processor**
  # stage (`prepare_messages` → `project`, `handle_message` → transform), i.e.
  # OUTSIDE the dispatch transaction, so that:
  #
  #   * the host's `project/3` (untrusted, possibly I/O-bound) and the user-authored
  #     Lua transform never hold a DB connection or row locks; and
  #   * a `project`/transform failure becomes **data** (a parked/cancelled spec),
  #     never a transaction error — so one bad subscription transform can never roll
  #     back a batch nor block sibling subscriptions.
  #
  # The change module `AshIntegration.Outbound.Dispatch.Changes.DispatchEvent` consumes these
  # specs inside `after_batch` and writes them atomically with the `dispatched_at`
  # stamp. Nothing here touches the database.

  alias AshIntegration.Outbound.Delivery.Resolver
  alias AshIntegration.Outbound.Wire.Envelope

  @type spec :: %{:attrs => map(), :coalesce? => boolean(), optional(:failure_kind) => atom()}

  @doc """
  Run the producer's batched `project/3` **once** over the whole `(type, version)`
  group against the shared candidate `subscriptions`. Returns `{:ok, decisions}`
  (a `%{event_id => decision}` map) or `{:error, reason}` if `project` raised —
  fail-closed, the caller parks every candidate. Called once per group in the
  processor's `prepare_messages`.
  """
  @spec project(module(), [map()], [map()]) :: {:ok, map()} | {:error, String.t()}
  def project(producer, events, subscriptions) do
    case producer.project(events, subscriptions, %{}) do
      decisions when is_non_struct_map(decisions) ->
        {:ok, decisions}

      # `project/3` is contracted to return a plain `%{event_id => decision}` map. Any
      # other return is a producer bug: treat it as the documented fail-closed park-all
      # path (`{:error, reason}`) rather than letting the caller's `Map.get/3` mishandle
      # it. NB `is_non_struct_map/1`, not `is_map/1` — a struct IS a map, so `is_map`
      # would let e.g. a `MapSet` through, and `Map.get(struct, id, default)` then
      # returns the default for every event → a SILENT skip-all, the exact opposite of
      # fail-closed. Routing structs here parks every candidate instead.
      other ->
        {:error, "project returned a non-map: #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Build the EventDelivery specs for a single `event` against `subscriptions`,
  applying `outcome` (the per-group `project` result, resolved per event):

    * `{:park_all, reason}` — `project` raised or no producer is registered: park a
      delivery for every candidate (fail-closed, recoverable via reprocess).
    * `{:decision, decision}` — the `project` decision for this event (`:skip` →
      no rows; `:deliver`/`{:deliver, data}`; `{:per_subscription, map}`; anything
      else → park all, a producer bug).

  Runs the Lua transform (`Resolver`) per `(event, subscription)` to resolve
  the wire descriptor; a transform skip → `:cancelled`, a transform error →
  `:parked`. Subscriptions must have their `connection` (with owner) loaded.
  """
  @spec specs_for_event(map(), [map()], {:park_all, String.t()} | {:decision, term()}) :: [spec()]
  def specs_for_event(event, subscriptions, {:park_all, reason}) do
    Enum.map(subscriptions, &park_spec(event, &1, reason, :project))
  end

  def specs_for_event(event, subscriptions, {:decision, decision}) do
    apply_decision(event, subscriptions, decision)
  end

  # ── Decision → specs (fail-closed) ─────────────────────────────────────────

  # No row — the immutable Event remains the audit.
  defp apply_decision(_event, _subscriptions, {:skip, _reason}), do: []

  defp apply_decision(event, subscriptions, :deliver) do
    Enum.map(subscriptions, &materialize_spec(event, &1, event.data))
  end

  defp apply_decision(event, subscriptions, {:deliver, projected}) when is_map(projected) do
    Enum.map(subscriptions, &materialize_spec(event, &1, projected))
  end

  defp apply_decision(event, subscriptions, {:per_subscription, by_sub}) when is_map(by_sub) do
    Enum.flat_map(subscriptions, fn sub ->
      apply_sub_decision(event, sub, Map.get(by_sub, sub.id, {:skip, "unauthorized"}))
    end)
  end

  # A non-map projection / malformed decision is a producer bug — park rather than
  # ship full unredacted data (a non-map projection is most likely a botched
  # redaction). Fail-closed, recoverable via reprocess.
  defp apply_decision(event, subscriptions, other) do
    reason = "project returned an invalid decision: #{inspect(other)}"
    Enum.map(subscriptions, &park_spec(event, &1, reason, :project))
  end

  defp apply_sub_decision(event, sub, :deliver), do: [materialize_spec(event, sub, event.data)]

  defp apply_sub_decision(event, sub, {:deliver, projected}) when is_map(projected),
    do: [materialize_spec(event, sub, projected)]

  defp apply_sub_decision(_event, _sub, {:skip, _reason}), do: []

  defp apply_sub_decision(event, sub, other) do
    [
      park_spec(
        event,
        sub,
        "project returned an invalid per-subscription decision: #{inspect(other)}",
        :project
      )
    ]
  end

  # Resolve the full transport-shaped descriptor (config defaults + transform over
  # `data`); the signature/auth are NOT applied here — they are live carve-outs
  # added at delivery. Transform skip → cancelled; transform error → parked; ok → pending.
  defp materialize_spec(event, subscription, data) do
    envelope = build_envelope(event, data)

    case Resolver.resolve(
           subscription.connection,
           subscription,
           envelope,
           event.created_at
         ) do
      :skip ->
        cancelled_spec(event, subscription, "Skipped by transform")

      {:ok, delivery, body_hash} ->
        pending_spec(event, subscription, delivery, body_hash)

      {:error, lua_error} ->
        park_spec(event, subscription, "Transform error: #{lua_error}", :transform)
    end
  end

  # ── Spec constructors ──────────────────────────────────────────────────────

  # Only pending deliveries can supersede a sibling, and a `notify_on_every_change`
  # subscription opts out of coalescing entirely — so we bake the decision in here,
  # where the subscription is in hand, rather than re-loading it inside the txn.
  defp pending_spec(event, subscription, delivery, body_hash) do
    %{
      attrs:
        Map.merge(base_attrs(event, subscription), %{
          delivery: delivery,
          body_hash: body_hash,
          state: :pending
        }),
      coalesce?: not subscription.notify_on_every_change
    }
  end

  # `failure_kind` (`:project`/`:transform`) is carried on the spec so the caller
  # can emit `:parked` telemetry after the row is persisted (see DispatchEvent).
  defp park_spec(event, subscription, reason, failure_kind) do
    event
    |> spec(subscription, %{delivery: nil, state: :parked, last_error: reason})
    |> Map.put(:failure_kind, failure_kind)
  end

  defp cancelled_spec(event, subscription, reason) do
    spec(event, subscription, %{delivery: nil, state: :cancelled, last_error: reason})
  end

  defp spec(event, subscription, overrides) do
    %{attrs: Map.merge(base_attrs(event, subscription), overrides), coalesce?: false}
  end

  defp base_attrs(event, subscription) do
    %{
      event_id: event.id,
      event_type: event.event_type,
      version: event.version,
      event_key: event.event_key,
      subscription_id: subscription.id,
      connection_id: subscription.connection_id
    }
  end

  # The wire `event-id` is the immutable Event's id; built via the shared
  # `Envelope.transform_input/1` so dispatch and reprocess inputs stay
  # byte-identical. `created_at` is the Event's immutable occurrence time.
  defp build_envelope(event, data) do
    Envelope.transform_input(%{
      id: event.id,
      type: event.event_type,
      version: event.version,
      event_key: event.event_key,
      created_at: event.created_at,
      subject: event.source_resource_id,
      data: data
    })
  end
end
