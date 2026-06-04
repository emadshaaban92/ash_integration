defmodule AshIntegration.Outbound.Declare.Producer do
  @moduledoc """
  Behaviour for an event type's **producer** — one module per event type that
  both *captures* the immutable fact and *projects* it per subscription.

  The version is **data, not structure**: it flows through the callbacks as an
  argument, so a single producer module handles every version of its event type
  (pattern-match on the version, or share via private helpers — there is no
  per-version module).

  Reference it from an `event` declaration in the `outbound_events` DSL:

      event "stock.changed" do
        actions [:update, :destroy]
        producer MyApp.Outbound.StockChanged
        version 1
        version 2
      end

      defmodule MyApp.Outbound.StockChanged do
        use AshIntegration.Outbound.Declare.Producer
        # produce/3, example/1, event_key/2, project/3 ...
      end

  ## The two halves: capture (`produce`) and fan-out (`project`)

  `produce/3` runs **once per subscribed version, synchronously, in the source
  transaction** under the producer/system's own authority — there is **no
  per-actor authorized read** here; authorization lives in `project/3`. It
  captures the **immutable Event** from the change's in-memory records, so a
  destroy still carries real data and the captured `data` is point-in-time (T0).

  `project/3` runs **asynchronously at dispatch**, once per `(event_type,
  version)` batch over the candidate subscriptions. It is the **single
  host-owned hook** that decides who gets the event and what it looks like for
  them — authorization, routing, and redaction in one pass. It is **required**:
  silence is never "deliver" (see the fail-closed default below).

  ## The produce/project consistency boundary

  Capture in `produce` what must be true-as-of-T0 (point-in-time); defer to
  `project` what is inherently dispatch-time (subscriber-dependent: scoping,
  redaction) or what the host explicitly accepts as T1. A field captured in
  `produce` is T0-consistent; a field enriched in `project` reflects dispatch
  time. The default — capture the in-memory record — is cheap *and* correct.

  ## The `event_key` invariant (host responsibility, unchecked)

  `event_key/2` derives the partition identity for ordering + coalescing from a
  produced `data` map. It takes the version (to parse the data) but **must return
  a value-stable key per entity**: `event_key(1, v1_of_order_123)` and
  `event_key(2, v2_of_order_123)` must be equal, so a connection holding both a
  v1 and a v2 subscription keeps both representations on one correctly-ordered
  lane. The framework cannot check this (it has no other entity identifier to
  diff against). Returning a key **coarser** than the data's snapshot scope
  makes coalescing silently drop siblings (data loss); **finer** merely forgoes
  cross-entity ordering.
  """

  @typedoc "An in-memory `{changeset, record}` pair, exactly as `after_batch` hands it."
  @type changeset_and_record :: {Ash.Changeset.t(), Ash.Resource.record()}

  @typedoc "The produced, pre-transform event body, stored as the Event's `data`."
  @type data :: map()

  @typedoc """
  Per-event fan-out decision returned by `project/3`, keyed by `Event` id.

    * `:deliver` — deliver to every candidate, event unchanged (the PUBLIC case).
    * `{:deliver, projected}` — deliver to every candidate, one shared projection.
    * `{:per_subscription, %{sub_id => sub_decision}}` — decide per subscription.
    * `{:skip, reason}` — deliver to none (audit only).
  """
  @type event_decision ::
          :deliver
          | {:deliver, projected_event :: map()}
          | {:per_subscription, %{optional(term()) => sub_decision()}}
          | {:skip, reason :: term()}

  @typedoc "Per-subscription decision inside a `:per_subscription` map."
  @type sub_decision ::
          :deliver | {:deliver, projected_event :: map()} | {:skip, reason :: term()}

  @doc """
  Capture the immutable `data`(s) for a batch of changes, at schema `version`.

  Receives the `{changeset, record}` pairs exactly as `after_batch` hands them
  (so the changeset's diff/before-image (`changeset.data`)/arguments/context are
  in reach — not just the post-change record) and a `context` map carrying the
  action + actor (constant across the batch), the extension point for later
  capture-time data. Mirrors `project/3`'s `context` arg.

  Returns a `%{record_id => data}` map — **batched over records** — where each
  value is the pre-transform body stored as the Event's `data`. Runs under
  producer/system authority (no per-actor read); a destroy's record is the final
  in-txn state, so its `data` carries real values.
  """
  @callback produce(
              version :: pos_integer(),
              changesets_and_records :: [changeset_and_record()],
              context :: map()
            ) :: %{optional(term()) => data()}

  @doc """
  Return a sample `data` map for `version`, mirroring `produce/3`'s output. Used
  for the transform preview and test actions; never called on the delivery hot path.
  """
  @callback example(version :: pos_integer()) :: data()

  @doc """
  Return the value-stable event key for a produced `data` map at `version` — the
  partition identity for ordering and coalescing (see the module doc's
  invariant). Pure; not batched.

  **Must return a non-empty `String.t()`.** The key is the `(connection, event_key)`
  ordering + coalescing lane *and* the `event-key` wire header, so it has to be a
  stable, non-empty string. The callback is mandatory, so there is no nil escape
  hatch: returning `nil`, a blank string, or any non-string term is a code bug and
  **raises** at capture rather than being coerced into — or papered over with — a
  garbage key. If you key on a non-string id, stringify it here (e.g. `to_string(id)`).
  """
  @callback event_key(version :: pos_integer(), data :: data()) :: String.t()

  @doc """
  Decide + project the event for each candidate subscription — authorization,
  routing, and redaction in one batched pass.

  `events` are every `Event` of this `(event_type, version)` batch; `subscriptions`
  are the candidate set (connection + owner preloaded), passed once. `context` is
  reserved (tracer, source action) and may be empty.

  Returns a `%{event_id => event_decision}` map. **Fail-closed:** an `event_id`
  missing from the result, or a `subscription_id` missing from a
  `:per_subscription` map, is treated as `{:skip, "unauthorized"}` — silence never
  means deliver. A `project/3` that **raises** is a code bug: the affected events'
  deliveries are created `parked` for an operator to fix and reprocess.

  Public is a one-liner: `Map.new(events, &{&1.id, :deliver})`.
  """
  @callback project(
              events :: [Ash.Resource.record()],
              subscriptions :: [Ash.Resource.record()],
              context :: map()
            ) :: %{optional(term()) => event_decision()}

  defmacro __using__(_opts) do
    quote do
      @behaviour AshIntegration.Outbound.Declare.Producer
    end
  end
end
