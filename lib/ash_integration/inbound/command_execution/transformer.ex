defmodule AshIntegration.Inbound.CommandExecution.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.{Change, Dsl, Info}
  alias AshIntegration.Inbound.Execute.Changes
  alias Spark.Dsl.Transformer

  # `:pending` — in the machine, not terminal. `claimed_at` set = claimed/in-flight;
  #   `claimed_at` NULL = enqueued, awaiting a claimer.
  # `:applied` — terminal success; caches `result` for idempotent replay.
  # `:failed` — terminal, deterministic failure (decode/unknown/build/business
  #   rejection/derive). Never retried by the machinery.
  # `:dead_lettered` — transient failures exhausted on a transport that cannot
  #   redeliver. The table is the retry source (`:retry` resets to `:pending`).
  #   Never reaped by retention.
  # `:parked` — RESERVED, not built: the slot for a future per-key ordering gate.
  @states [:pending, :applied, :failed, :dead_lettered, :parked]

  @doc false
  def states, do: @states

  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    {:ok,
     dsl_state
     |> add_primary_key_if_not_exists()
     |> add_attribute_if_not_exists(:command_source, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:command_id, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:command_type, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:raw_command_type, :string, allow_nil?: false, public?: true)
     # Stored as text (Ash `:atom`), `one_of` checked at cast time from the single
     # source-of-truth `Inbound.Transport.transports/0` — so adding a transport is
     # a code change, never a migration.
     |> add_attribute_if_not_exists(:transport, :atom,
       allow_nil?: false,
       public?: true,
       constraints: [one_of: AshIntegration.Inbound.Transport.transports()]
     )
     # Reserved ordering key (§ordering). No runtime behavior yet — stored so the
     # future gate needs no migration.
     |> add_attribute_if_not_exists(:partition_key, :string, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:payload, :map, allow_nil?: true, public?: true)
     # "Persist what the transport cannot give back." Populated for `:response`
     # derive failures (the captured one-shot artifact); nil for kafka/http (the
     # transport itself is the replay source).
     |> add_attribute_if_not_exists(:raw, :map, allow_nil?: true, public?: true)
     # The handler result cached on `:applied`, returned verbatim on idempotent
     # replay.
     |> add_attribute_if_not_exists(:result, :map, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:state, :atom,
       allow_nil?: false,
       public?: true,
       default: :pending,
       constraints: [one_of: @states]
     )
     |> add_attribute_if_not_exists(:error, :string, allow_nil?: true, public?: true)
     # Bumped ON CLAIM (same crash-safety as the delivery relay: a worker that
     # dies mid-apply still incremented, so the ceiling bounds a crash loop).
     |> add_attribute_if_not_exists(:attempts, :integer,
       allow_nil?: false,
       public?: true,
       default: 0
     )
     # The soft lease AND the fence token: every finalizing write filters on it.
     |> add_attribute_if_not_exists(:claimed_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     # Durable backoff cursor for transient retries, honored by the claim.
     |> add_attribute_if_not_exists(:next_attempt_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     # Stamped once on `:applied`; a dedicated column, not an overloaded `updated_at`.
     |> add_attribute_if_not_exists(:applied_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_update_timestamp_if_not_exists(:updated_at)
     |> add_actor_relationship_if_not_exists()
     |> add_source_delivery_relationship_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_admit_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_apply_success_action_if_not_exists()
     |> add_apply_failure_action_if_not_exists()
     |> add_record_attempt_error_action_if_not_exists()
     |> add_dead_letter_action_if_not_exists()
     |> add_retry_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_unique_identity_if_not_exists()
     |> add_actor_reference_if_not_exists()
     |> add_source_delivery_reference_if_not_exists()
     |> add_index_if_not_exists([:source_delivery_id])
     |> add_index_if_not_exists([:command_type, :state])
     |> add_index_if_not_exists([:state, :updated_at])
     |> add_claim_index_if_not_exists()
     |> add_ordering_lane_index_if_not_exists()}
  end

  # ── Attributes ──────────────────────────────────────────────────────────

  defp add_primary_key_if_not_exists(dsl_state) do
    if Info.attribute(dsl_state, :id) do
      dsl_state
    else
      # DB-generated UUIDv7 (Postgres `uuidv7()`). Rows are inserted when the
      # command arrives/is captured, so the id is occurrence-ordered and doubles
      # as the claim's FIFO cursor — the same property the outbound side gets from
      # the Event id.
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
      |> Spark.Dsl.Transformer.set_option([:postgres], :migration_defaults,
        id: "fragment(\"uuidv7()\")"
      )
    end
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

  # The actor snapshot taken at admission. Snapshotted — not resolved live at
  # apply — so execution survives a later owner change or connection deletion, and
  # a retry replays under the same authority the command was admitted with.
  defp add_actor_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :actor) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :actor,
          destination: AshIntegration.actor_resource(),
          allow_nil?: true,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  # Provenance link for the `:response` transport (dashboard drill-down: delivery
  # → command). Nilified rather than cascaded on delete so the two retention
  # windows stay independent. Nil for push transports.
  defp add_source_delivery_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :source_delivery) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :source_delivery,
          destination: AshIntegration.event_delivery_resource(),
          domain: AshIntegration.domain(),
          allow_nil?: true,
          public?: true
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

    has_read? = Enum.any?(existing_defaults, &(match?(:read, &1) or match?({:read, _}, &1)))

    has_destroy? =
      Enum.any?(existing_defaults, &(match?(:destroy, &1) or match?({:destroy, _}, &1)))

    additions = if(has_read?, do: [], else: [:read]) ++ if(has_destroy?, do: [], else: [:destroy])

    case additions do
      [] ->
        dsl_state

      _ ->
        Transformer.set_option(dsl_state, [:actions], :defaults, existing_defaults ++ additions)
    end
  end

  # ── Create (admission) ────────────────────────────────────────────────────

  # The admission insert. Accepts every column the core sets at admission — the
  # create is library-driven (the core builds the changeset), not a user-facing
  # form, so a broad accept is appropriate. Push transports insert with
  # `claimed_at` pre-stamped + `attempts: 1` (insert-as-claim); the response
  # transport inserts unclaimed; a terminal admission failure inserts `state:
  # :failed` directly. A unique conflict on the identity is the dedup signal,
  # handled by the core (read the existing row, return `{:duplicate, …}`).
  defp add_admit_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :admit) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :create,
          name: :admit,
          primary?: true,
          accept: [
            :command_source,
            :command_id,
            :command_type,
            :raw_command_type,
            :transport,
            :partition_key,
            :payload,
            :raw,
            :state,
            :error,
            :attempts,
            :claimed_at,
            :actor_id,
            :source_delivery_id
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Read actions ──────────────────────────────────────────────────────────

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

  # ── Update actions (state transitions) ──────────────────────────────────

  # Terminal success. Caches `result`, stamps `applied_at`, clears the error and
  # the lease. Guarded on `state == :pending`; the relay/inline caller layers the
  # `claimed_at` fence on top at its call site.
  defp add_apply_success_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :apply_success) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :apply_success,
          accept: [:result],
          require_atomic?: false,
          changes: [
            guard_pending(),
            set_state(:applied),
            set_applied_at(),
            clear_error(),
            release_lease()
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Terminal, deterministic failure. Caches `error`; never retried.
  defp add_apply_failure_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :apply_failure) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :apply_failure,
          accept: [:error],
          require_atomic?: false,
          changes: [guard_pending(), set_state(:failed), release_lease()]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Transient failure with retry budget left: record the error + durable backoff
  # cursor, release the lease, leave the row `:pending` for the relay to re-claim.
  # `attempts` is NOT bumped here — the claim bumps it (crash-safe).
  defp add_record_attempt_error_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :record_attempt_error) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :record_attempt_error,
          accept: [:error, :next_attempt_at],
          require_atomic?: false,
          changes: [guard_pending(), release_lease()]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Transient failures exhausted on a transport that cannot redeliver. Terminal
  # until an operator `:retry`. Never reaped.
  defp add_dead_letter_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :dead_letter) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :dead_letter,
          accept: [:error],
          require_atomic?: false,
          changes: [guard_pending(), set_state(:dead_lettered), release_lease()]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Operator recourse: return a `:dead_lettered` row to `:pending`, clearing the
  # bookkeeping so the relay's next claim starts clean. Guarded on
  # `state == :dead_lettered` so it can only ever un-stick a dead letter.
  defp add_retry_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :retry) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :retry,
          accept: [],
          require_atomic?: false,
          changes: [guard_dead_lettered(), set_state(:pending), clear_error(), clear_claim()]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp set_state(value) do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: {Change.SetAttribute, [attribute: :state, value: value]}
    )
  end

  defp set_applied_at do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: {Change.SetAttribute, [attribute: :applied_at, value: &DateTime.utc_now/0]}
    )
  end

  defp clear_error do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: {Change.SetAttribute, [attribute: :error, value: nil]}
    )
  end

  defp guard_pending do
    Transformer.build_entity!(Dsl, [:actions, :update], :change, change: Changes.GuardPending)
  end

  defp guard_dead_lettered do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: Changes.GuardDeadLettered
    )
  end

  defp release_lease do
    Transformer.build_entity!(Dsl, [:actions, :update], :change, change: Changes.ReleaseLease)
  end

  defp clear_claim do
    Transformer.build_entity!(Dsl, [:actions, :update], :change, change: Changes.ClearClaim)
  end

  # ── Code interface ──────────────────────────────────────────────────────

  defp add_code_interface_if_not_exists(dsl_state) do
    existing = Transformer.get_entities(dsl_state, [:code_interface])

    if Enum.any?(existing, &(&1.name == :admit)) do
      dsl_state
    else
      defines = [
        {:admit, [action: :admit]},
        {:read_all, [action: :read]},
        {:retry, [action: :retry]},
        {:destroy, [action: :destroy]}
      ]

      Enum.reduce(defines, dsl_state, fn {name, opts}, state ->
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
  end

  # ── Identity (idempotency) ──────────────────────────────────────────────

  # The composite idempotency identity. The dedup mechanism, not a backstop:
  # admission relies on the conflict (a duplicate gets a fast unique-violation →
  # the core reads the existing row and returns `{:duplicate, state, result}`).
  defp add_unique_identity_if_not_exists(dsl_state) do
    existing =
      dsl_state
      |> Transformer.get_entities([:identities])
      |> Enum.find(&(&1.name == :unique_command_identity))

    if existing do
      dsl_state
    else
      {:ok, identity} =
        Transformer.build_entity(Dsl, [:identities], :identity,
          name: :unique_command_identity,
          keys: [:command_source, :command_id]
        )

      Transformer.add_entity(dsl_state, [:identities], identity, type: :append)
    end
  end

  # ── Postgres references & indexes ───────────────────────────────────────

  defp add_actor_reference_if_not_exists(dsl_state),
    do: add_reference_if_not_exists(dsl_state, :actor, on_delete: :nilify, on_update: :restrict)

  defp add_source_delivery_reference_if_not_exists(dsl_state) do
    add_reference_if_not_exists(dsl_state, :source_delivery,
      on_delete: :nilify,
      on_update: :restrict
    )
  end

  defp add_reference_if_not_exists(dsl_state, relationship, opts) do
    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :references])
      |> Enum.find(&(&1.relationship == relationship))

    if existing do
      dsl_state
    else
      {:ok, reference} =
        Transformer.build_entity(
          AshPostgres.DataLayer,
          [:postgres, :references],
          :reference,
          Keyword.put(opts, :relationship, relationship)
        )

      Transformer.add_entity(dsl_state, [:postgres, :references], reference, type: :append)
    end
  end

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

  # The relay's claim scan (FIFO by occurrence-ordered id), partial on the small
  # live `:pending` frontier.
  defp add_claim_index_if_not_exists(dsl_state) do
    add_partial_index_if_not_exists(
      dsl_state,
      "idx_command_executions_claim",
      [:id],
      "state = 'pending'"
    )
  end

  # Reserved for the future per-key ordering gate (mirrors the outbound
  # schedulable-lane index). Cheap to carry now; saves a backfill-under-load later.
  defp add_ordering_lane_index_if_not_exists(dsl_state) do
    add_partial_index_if_not_exists(
      dsl_state,
      "idx_command_executions_ordering_lane",
      [:partition_key, :id],
      "state IN ('pending', 'parked')"
    )
  end

  defp add_partial_index_if_not_exists(dsl_state, name, fields, where) do
    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.find(&(&1.name == name))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          name: name,
          fields: fields,
          where: where
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end
end
