defmodule AshIntegration.Outbound.Capture.Event.Transformer do
  @moduledoc false
  # Injects the immutable Event schema: the fact, captured once in the source txn.
  # No delivery state and no update actions — it is write-once. The library injects
  # the base attributes; the host may add their own.
  use Spark.Dsl.Transformer

  alias Ash.Resource.{Change, Dsl, Info}
  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    {:ok,
     dsl_state
     |> add_primary_key_if_not_exists()
     |> add_attribute_if_not_exists(:event_type, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:version, :integer, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:event_key, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:source_resource, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:source_resource_id, :string,
       allow_nil?: false,
       public?: true
     )
     |> add_attribute_if_not_exists(:source_action, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:data, :map, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:dispatched_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     |> add_attribute_if_not_exists(:claimed_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     |> add_attribute_if_not_exists(:dispatch_attempts, :integer,
       allow_nil?: false,
       public?: true,
       default: 0
     )
     # The dispatch terminal bit (poison). `nil` ⇒ not terminal — `claim/1` refuses
     # an event iff this is set. Mirrors `EventDelivery.terminal_reason`, narrowed to
     # a single reason: `:expired`, set by the opt-in age sweep. There is deliberately
     # no attempt ceiling and no `:permanent` (a deterministic materialization failure
     # is a bug to fix, not a terminal state) — see `design/dispatch-terminal-model.md`.
     |> add_attribute_if_not_exists(:dispatch_terminal_reason, :atom,
       allow_nil?: true,
       public?: true,
       constraints: [one_of: [:expired]]
     )
     |> add_attribute_if_not_exists(:dispatch_error, :string,
       allow_nil?: true,
       public?: true
     )
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_update_timestamp_if_not_exists(:updated_at)
     |> add_deliveries_relationship_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_create_action_if_not_exists()
     |> add_mark_dispatched_action_if_not_exists()
     |> add_dispatch_action_if_not_exists()
     |> add_expire_dispatch_action_if_not_exists()
     |> add_reset_dispatch_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_index_if_not_exists([:event_type, :version])
     |> add_index_if_not_exists([:source_resource, :source_resource_id])
     |> add_undispatched_lane_index_if_not_exists()
     |> add_outbox_claim_index_if_not_exists()
     |> add_retention_index_if_not_exists()}
  end

  # ── Attributes ──────────────────────────────────────────────────────────

  defp add_primary_key_if_not_exists(dsl_state) do
    if Info.attribute(dsl_state, :id) do
      dsl_state
    else
      {:ok, pk} =
        Transformer.build_entity(Dsl, [:attributes], :attribute,
          name: :id,
          type: :uuid_v7,
          primary_key?: true,
          allow_nil?: false,
          writable?: false,
          generated?: true,
          public?: true
        )

      dsl_state
      |> Transformer.add_entity([:attributes], pk, type: :prepend)
      |> put_migration_default(:id, "fragment(\"uuidv7()\")")
    end
  end

  # MERGE the library's `id` migration default into whatever the host already set,
  # rather than `set_option`-replacing the whole keyword. A bare `set_option` here
  # would silently wipe a host's own `migration_defaults` (e.g. a default they set on
  # one of their added attributes). This branch only runs when the host hasn't
  # defined `:id` themselves, so overwriting just the `:id` key is safe.
  defp put_migration_default(dsl_state, key, value) do
    existing = Transformer.get_option(dsl_state, [:postgres], :migration_defaults) || []

    Spark.Dsl.Transformer.set_option(
      dsl_state,
      [:postgres],
      :migration_defaults,
      Keyword.put(existing, key, value)
    )
  end

  defp add_attribute_if_not_exists(dsl_state, name, type, opts) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      opts = opts |> Keyword.put(:name, name) |> Keyword.put(:type, type)
      {:ok, attribute} = Transformer.build_entity(Dsl, [:attributes], :attribute, opts)
      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  defp add_create_timestamp_if_not_exists(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(Dsl, [:attributes], :create_timestamp, name: name, public?: true)

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  defp add_update_timestamp_if_not_exists(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(Dsl, [:attributes], :update_timestamp, name: name, public?: true)

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  # ── Relationships ───────────────────────────────────────────────────────

  defp add_deliveries_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :deliveries) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :has_many,
          name: :deliveries,
          destination: AshIntegration.event_delivery_resource(),
          destination_attribute: :event_id,
          domain: AshIntegration.domain()
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  # ── Defaults ────────────────────────────────────────────────────────────

  defp add_default_accept_if_not_set(dsl_state) do
    case Transformer.get_option(dsl_state, [:actions], :default_accept) do
      nil -> Transformer.set_option(dsl_state, [:actions], :default_accept, [])
      _ -> dsl_state
    end
  end

  defp add_defaults_if_not_set(dsl_state) do
    existing_defaults = Transformer.get_option(dsl_state, [:actions], :defaults) || []

    # Only add a default the host lacks — see `default_present?/3`.
    additions =
      Enum.reject([:read, :destroy], &default_present?(dsl_state, existing_defaults, &1))

    case additions do
      [] ->
        dsl_state

      _ ->
        Transformer.set_option(dsl_state, [:actions], :defaults, existing_defaults ++ additions)
    end
  end

  # A default is "present" if it's already in the `defaults` list OR the host defined
  # an action of that name explicitly. `Ash.Resource.Transformers.SetPrimaryActions`
  # turns each `defaults` entry into a `prepend_action(type)` WITHOUT deduping against
  # a hand-written `read :read`/`destroy :destroy`, so injecting a default the host
  # already defined produces two actions with the same name → a "Got duplicate action"
  # DSL error pointing at library code the host never wrote.
  defp default_present?(dsl_state, existing_defaults, type) do
    Enum.any?(existing_defaults, fn
      ^type -> true
      {^type, _} -> true
      _ -> false
    end) or not is_nil(Info.action(dsl_state, type))
  end

  # ── Create (write-once; no update actions) ───────────────────────────────

  defp add_create_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :create) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :create,
          name: :create,
          primary?: true,
          accept: [
            :event_type,
            :version,
            :event_key,
            :source_resource,
            :source_resource_id,
            :source_action,
            :data,
            # Capture leaves this NULL (the relay stamps it); accepted so seeds and
            # tests can construct a fully-dispatched Event directly.
            :dispatched_at
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Mark-dispatched (relay bookkeeping on the otherwise-immutable Event) ───
  # Sets `dispatched_at`, flipping the event out of the outbox once the relay has
  # materialized all its deliveries. Also accepts `dispatch_error` (set on a failed
  # attempt — including the terminal/poison one, which deliberately leaves
  # `dispatched_at` NULL so the event stays stuck; nil clears it on a clean
  # dispatch). It touches no part of the fact itself. This is also the seam a host
  # can use to define its own poison policy (e.g. a change that stamps
  # `dispatched_at` once `dispatch_error` is set) — the library never does so.
  defp add_mark_dispatched_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :mark_dispatched) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :mark_dispatched,
          accept: [:dispatched_at, :dispatch_error],
          require_atomic?: false
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Dispatch (transactional fan-out + ack) ────────────────────────────────
  # The bulk-update action the relay drives over claimed Events. Stamps
  # `dispatched_at` (and clears `dispatch_error`) AND materializes every planned
  # `EventDelivery` (+ coalesces) atomically — both inside the batch transaction
  # (`after_batch`), so an event is dispatched iff its deliveries exist. The
  # delivery specs are precomputed outside the txn (Broadway processor stage) and
  # passed via `context: %{dispatch_plan: ...}`. `touches_resources` lets the txn
  # span the EventDelivery table; `require_atomic? false` because the change does
  # record-based, cross-resource writes in `after_batch`.
  defp add_dispatch_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :dispatch) do
      dsl_state
    else
      change =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshIntegration.Outbound.Dispatch.Changes.DispatchEvent
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :dispatch,
          accept: [],
          require_atomic?: false,
          touches_resources: [AshIntegration.event_delivery_resource()],
          changes: [change]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Expire dispatch (opt-in age-based give-up; the terminal write) ────────
  # The opt-in age sweep (`Dispatcher.sweep_expired/0`, driven by `Retention`): stamp
  # `dispatch_terminal_reason: :expired` on an undispatched Event older than the
  # configured `max_dispatch_age_ms`, taking it terminal (`claim/1` refuses it; its
  # lane stays blocked). The caller pushes the `is_nil(dispatched_at) and
  # is_nil(dispatch_terminal_reason) and created_at < cutoff` precondition into the
  # query, keeping the action atomic-executable so the sweep is one bulk UPDATE
  # through Ash (so `updated_at` bumps and host notifiers fire). Mirrors the delivery
  # `:expire` action — see `design/dispatch-terminal-model.md`.
  defp add_expire_dispatch_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :expire_dispatch) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :expire_dispatch,
          accept: [],
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change:
                {Change.SetAttribute, [attribute: :dispatch_terminal_reason, value: :expired]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Reset dispatch (un-poison; operator recourse) ─────────────────────────
  # Clears the terminal bookkeeping so a stuck/poison (`:expired`) Event becomes
  # claimable again: `dispatch_terminal_reason`/`claimed_at`/`dispatch_error` → nil.
  # Deliberately does NOT reset `dispatch_attempts` — the count is a monotonic,
  # honest history (mirrors `EventDelivery.attempts`), and with no attempt ceiling it
  # no longer gates the claim. Does NOT touch `dispatched_at`, so an already-dispatched
  # Event stays out of the outbox (the reset is then a harmless no-op). The relay
  # re-claims on its next poll and does the actual fan-out.
  defp add_reset_dispatch_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :reset_dispatch) do
      dsl_state
    else
      change =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshIntegration.Outbound.Dispatch.Changes.ResetDispatch
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :reset_dispatch,
          accept: [],
          require_atomic?: false,
          changes: [change]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Read actions ─────────────────────────────────────────────────────────

  defp add_index_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :index) do
      dsl_state
    else
      prepare =
        Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
          preparation: {Ash.Resource.Preparation.Build, [sort: [id: :desc]]}
        )

      pagination =
        Transformer.build_entity!(Dsl, [:actions, :read], :pagination,
          keyset?: true,
          offset?: true,
          default_limit: 20,
          countable: :by_default
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :index,
          preparations: [prepare],
          pagination: pagination
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Code interface ─────────────────────────────────────────────────────

  defp add_code_interface_if_not_exists(dsl_state) do
    existing_names =
      dsl_state
      |> Transformer.get_entities([:code_interface])
      |> MapSet.new(& &1.name)

    defines = [
      {:create, [action: :create]},
      {:read_all, [action: :read]},
      {:reset_dispatch, [action: :reset_dispatch]},
      {:destroy, [action: :destroy]}
    ]

    # Add each `define` only when the host hasn't already defined one of that NAME.
    # The old `if any create? -> skip all` sentinel meant a host who defined even one
    # of these interfaces (say `define :destroy`) without a `:create` got the whole
    # library set re-added on top → a duplicate `define` for the name they wrote,
    # which is a DSL error. Per-name filtering lets a host override any single
    # interface without tripping over the rest.
    defines
    |> Enum.reject(fn {name, _opts} -> MapSet.member?(existing_names, name) end)
    |> Enum.reduce(dsl_state, fn {name, opts}, state ->
      {:ok, define} =
        Transformer.build_entity(
          Dsl,
          [:code_interface],
          :define,
          Keyword.put(opts, :name, name)
        )

      Transformer.add_entity(state, [:code_interface], define, type: :append)
    end)
  end

  # ── Postgres indexes ─────────────────────────────────────────────────────

  defp add_index_if_not_exists(dsl_state, fields) do
    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.find(&(&1.fields == fields))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          fields: fields
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  # Partial index over the outbox frontier — keeps the scheduler high-water gate's
  # `NOT EXISTS (older same-key event still undispatched)` check cheap, since only
  # the (normally few) undispatched rows are indexed.
  defp add_undispatched_lane_index_if_not_exists(dsl_state) do
    index_name = "idx_events_undispatched_lane"

    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.find(&(&1.name == index_name))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          name: index_name,
          fields: [:event_key, :id],
          where: "dispatched_at IS NULL"
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  # Serves the relay's claim query — `WHERE dispatched_at IS NULL ORDER BY
  # id ... FOR UPDATE SKIP LOCKED` — without scanning dispatched history. Partial
  # on the outbox frontier, which is normally small. (The `undispatched_lane`
  # index above leads with `event_key` for the scheduler gate; this one is on
  # `id` alone — the UUIDv7 PK, which is occurrence-ordered — for the FIFO claim.)
  defp add_outbox_claim_index_if_not_exists(dsl_state) do
    index_name = "idx_events_outbox_claim"

    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.find(&(&1.name == index_name))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          name: index_name,
          fields: [:id],
          where: "dispatched_at IS NULL"
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  defp add_retention_index_if_not_exists(dsl_state) do
    index_name = "idx_events_retention"

    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.find(&(&1.name == index_name))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          name: index_name,
          fields: [:created_at],
          where: "dispatched_at IS NOT NULL"
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end
end
