defmodule AshIntegration.Outbound.Delivery.EventDelivery.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.{Change, Dsl, Info}
  alias Spark.Dsl.Transformer

  # `:parked` is a build-failure state: the immutable Event exists, but `project`
  # or the transform raised, so there's no deliverable `delivery`. It is NOT
  # `pending`, so the scheduler never tries to deliver it, yet an older parked
  # delivery still blocks its `(connection, event_key)` lane (it's a candidate
  # "head"; see the scheduler). `:reprocess` moves it back to `:pending`; `:park`
  # moves it (back) in.
  # `:suppressed` is a terminal state for content-addressed suppression: the
  # delivery was resolved and found byte-identical to the last DELIVERED body on
  # its lane, so NO bytes were sent. It leaves the lane exactly like `:delivered`,
  # but is a distinct bucket so it never pollutes the operational meaning of
  # `:delivered` ("when did bytes last actually go out?"). See `Dedup` + the
  # content-suppression design doc.
  @states [:pending, :parked, :scheduled, :failed, :delivered, :suppressed, :cancelled]

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
     # The full transport-shaped delivery descriptor, resolved + signed at
     # dispatch (`AshIntegration.Outbound.Delivery.Resolver`) and replayed verbatim
     # at delivery — the snapshot-at-dispatch wire payload. Nil for a parked
     # (build-failed) or skipped delivery.
     |> add_attribute_if_not_exists(:delivery, :map, allow_nil?: true, public?: true)
     # Canonical content hash of a delivery's body (or a transform-set `dedup_on`),
     # computed at materialize for `suppress_unchanged` subscriptions (nil otherwise,
     # and for parked/cancelled rows). The scheduler compares it against the lane's
     # last DELIVERED body to decide content suppression (`Dedup`).
     |> add_attribute_if_not_exists(:body_hash, :string, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:state, :atom,
       allow_nil?: false,
       public?: true,
       default: :pending,
       constraints: [one_of: @states]
     )
     |> add_attribute_if_not_exists(:attempts, :integer,
       allow_nil?: false,
       public?: true,
       default: 0
     )
     |> add_attribute_if_not_exists(:last_error, :string, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:delivery_metadata, :map, allow_nil?: true, public?: true)
     # Soft-lease stamp: when the delivery relay claims a `:scheduled` row it sets
     # `claimed_at = now()` (and bumps `attempts`) so a second pass/node skips it
     # until the lease expires. Also the relay's fence token — a result-writing
     # action only finalizes a row whose `claimed_at` still matches what the claimer
     # saw, so a stale claimer (lease expired, row re-claimed) can't resurrect it.
     |> add_attribute_if_not_exists(:claimed_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     # Durable backoff cursor: a retryable delivery failure stamps the earliest time
     # the `:failed` row may next be promoted (`now + exp-backoff`, or a clamped
     # server `Retry-After`). The scheduler's PROMOTION honors it (`next_attempt_at IS
     # NULL OR next_attempt_at <= now()`); `nil` means "no wait". Purely timing — it
     # never encodes terminal-ness (that is `terminal_reason`). This is Oban's only
     # irreplaceable feature on the delivery side, made durable as a column.
     |> add_attribute_if_not_exists(:next_attempt_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     # Terminal-verdict marker, kept DISTINCT from `attempts` (an honest, monotonic
     # count) and `next_attempt_at` (timing). Set ⇒ the row is terminal: the scheduler
     # never promotes it, so it holds its lane forever (see the `{scheduled,failed}`
     # unique index) — recovery is operator-only. `:permanent` is a non-retryable
     # `:response` rejection (a 4xx/3xx the target refuses regardless of health);
     # `:expired` is the opt-in `max_delivery_age` give-up. `nil` ⇒ not terminal.
     # See `design/delivery-retry-model.md`.
     |> add_attribute_if_not_exists(:terminal_reason, :atom,
       allow_nil?: true,
       public?: true,
       constraints: [one_of: [:permanent, :expired]]
     )
     # Stamped once when `:deliver` marks the row `:delivered`; a dedicated column
     # rather than overloading `updated_at`.
     |> add_attribute_if_not_exists(:delivered_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_update_timestamp_if_not_exists(:updated_at)
     |> add_event_relationship_if_not_exists()
     |> add_subscription_relationship_if_not_exists()
     |> add_connection_relationship_if_not_exists()
     |> add_logs_relationship_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_create_action_if_not_exists()
     |> add_for_subscription_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_parked_action_if_not_exists()
     |> add_schedule_action_if_not_exists()
     |> add_deliver_action_if_not_exists()
     |> add_suppress_action_if_not_exists()
     |> add_record_failure_action_if_not_exists()
     |> add_cancel_action_if_not_exists()
     |> add_reprocess_action_if_not_exists()
     |> add_expire_action_if_not_exists()
     |> add_park_action_if_not_exists()
     |> add_reset_to_pending_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_unique_delivery_identity_if_not_exists()
     |> add_reference_if_not_exists(:event, on_delete: :delete, on_update: :restrict)
     |> add_reference_if_not_exists(:subscription, on_delete: :delete, on_update: :restrict)
     |> add_reference_if_not_exists(:connection, on_delete: :delete, on_update: :restrict)
     |> add_index_if_not_exists([:event_id])
     |> add_index_if_not_exists([:subscription_id, :state])
     |> add_index_if_not_exists([:connection_id, :event_key, :state])
     |> add_index_if_not_exists([:subscription_id, :event_key, :state])
     |> add_index_if_not_exists([:state, :updated_at])
     |> add_index_if_not_exists([:connection_id])
     |> add_partial_unique_index_if_not_exists()
     |> add_schedulable_lane_index_if_not_exists()
     |> add_delivery_claim_index_if_not_exists()
     |> add_dedup_baseline_index_if_not_exists()}
  end

  # ── Attributes ──────────────────────────────────────────────────────────

  defp add_primary_key_if_not_exists(dsl_state) do
    if Info.attribute(dsl_state, :id) do
      dsl_state
    else
      # DB-generated UUIDv7 (Postgres `uuidv7()`), not app-generated — the
      # database owns id minting. `generated?: true` keeps it out of inserts and
      # reads it back via RETURNING. (The delivery's id is dispatch-time; lane
      # ordering uses the parent Event's `event_id`, never this.)
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

  # Merge the library's `id` migration default into the host's existing keyword
  # rather than replacing it wholesale (a bare `set_option` would wipe host-set
  # defaults). Only runs when the host hasn't defined `:id` themselves.
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

  # The immutable Event upstream. `event_id` is the FK; the wire `event-id` is the
  # Event's id (baked into the cached `delivery` descriptor at dispatch), shared by
  # every delivery of that event.
  defp add_event_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :event) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :event,
          destination: AshIntegration.event_resource(),
          domain: AshIntegration.domain(),
          allow_nil?: false,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_subscription_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :subscription) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :subscription,
          destination: AshIntegration.subscription_resource(),
          domain: AshIntegration.domain(),
          allow_nil?: false,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  # connection_id is denormalized so the ordering index (connection_id, event_key)
  # is a single-table constraint.
  defp add_connection_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :connection) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :connection,
          destination: AshIntegration.connection_resource(),
          domain: AshIntegration.domain(),
          allow_nil?: false,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_logs_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :logs) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :has_many,
          name: :logs,
          destination: AshIntegration.delivery_log_resource(),
          destination_attribute: :event_delivery_id,
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
  # an action of that name explicitly. `SetPrimaryActions` expands each `defaults`
  # entry into an un-deduped `prepend_action`, so injecting a default the host already
  # defined yields a duplicate-action DSL error. See the matching note in
  # `AshIntegration.Outbound.Capture.Event.Transformer`.
  defp default_present?(dsl_state, existing_defaults, type) do
    Enum.any?(existing_defaults, fn
      ^type -> true
      {^type, _} -> true
      _ -> false
    end) or not is_nil(Info.action(dsl_state, type))
  end

  # ── Create ──────────────────────────────────────────────────────────────

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
            :delivery,
            :body_hash,
            :state,
            :last_error,
            :event_id,
            :subscription_id,
            :connection_id
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Read actions ────────────────────────────────────────────────────────

  defp add_for_subscription_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :for_subscription) do
      dsl_state
    else
      import Ash.Expr

      subscription_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :subscription_id,
          type: :uuid,
          allow_nil?: false
        )

      state_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :state,
          type: :atom,
          allow_nil?: true,
          constraints: [one_of: @states]
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter:
            expr(
              subscription_id == ^arg(:subscription_id) and
                (is_nil(^arg(:state)) or state == ^arg(:state))
            )
        )

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
          name: :for_subscription,
          arguments: [subscription_arg, state_arg],
          filters: [filter],
          preparations: [prepare],
          pagination: pagination
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

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

  # Parked (build-failed) deliveries for a connection — the `:parked` state.
  defp add_parked_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :parked) do
      dsl_state
    else
      import Ash.Expr

      argument =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :connection_id,
          type: :uuid,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter: expr(connection_id == ^arg(:connection_id) and state == :parked)
        )

      prepare =
        Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
          preparation: {Ash.Resource.Preparation.Build, [sort: [id: :asc]]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :parked,
          arguments: [argument],
          filters: [filter],
          preparations: [prepare]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Update actions (state transitions) ──────────────────────────────────

  # Promote `pending → scheduled`. The delivery relay claims `:scheduled` rows
  # directly (no Oban job to enqueue), so this only flips the state and clears the
  # lease/backoff bookkeeping so the freshly-scheduled row is immediately claimable
  # (a row re-promoted after a suspension reset must not inherit a stale
  # `claimed_at`/`next_attempt_at`). The scheduler guards the promote on
  # `state == :pending`; the partial unique index is the one-in-flight backstop.
  defp add_schedule_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :schedule) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :schedule,
          accept: [],
          require_atomic?: false,
          changes: [set_state(:scheduled), clear_claim()]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_deliver_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :deliver) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :deliver,
          accept: [:delivery_metadata],
          require_atomic?: false,
          # Guard: only a still-`:scheduled` row may be marked delivered. Under the
          # relay's `SKIP LOCKED` + soft-lease concurrency a stale claimer (lease
          # expired, row re-claimed/cancelled/reset) must NOT resurrect it to
          # `:delivered`. The relay additionally fences on the `claimed_at` lease
          # token at its call site.
          changes: [
            guard_scheduled(),
            set_state(:delivered),
            set_delivered_at(),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Outbound.Delivery.Changes.OnDeliverySuccess
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Content-suppression terminal transition: `pending → suppressed`. The scheduler
  # calls this instead of `:schedule` when the head's body equals the lane's last
  # delivered body — so a suppressed row never becomes `:scheduled`, never claimed.
  # It writes a `:suppressed` log row but — unlike `:deliver` — does NOT reset the
  # failure counters (a suppression touches no transport, so it proves nothing about
  # endpoint health; resetting would mask a degrading target). The scheduler pushes
  # the `state == :pending` precondition at the call site (as it does for `:schedule`).
  defp add_suppress_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :suppress) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :suppress,
          accept: [:last_error],
          require_atomic?: false,
          changes: [
            set_state(:suppressed),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Outbound.Delivery.Changes.OnDeliverySuppressed
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_record_failure_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :record_failure) do
      dsl_state
    else
      # The relay's SOLE failure outcome: move the in-flight row `:scheduled → :failed`.
      # It leaves the lane's in-flight slot but stays the lane's held head via the
      # `{scheduled,failed}` unique index, so per-key ordering holds and a terminal head
      # blocks its lane. `attempts` is NOT touched — the claim already bumped it (so a
      # relay that CRASHES mid-send still increments), keeping the count honest and
      # monotonic. Under A1 the relay stamps the timing/verdict it derived from the
      # transport result: either `next_attempt_at` (a retryable failure's backoff /
      # clamped `Retry-After`) OR `terminal_reason: :permanent` (a non-retryable
      # response) — never both. The `log_failure_class` argument is the class written
      # to the `Log`: the relay passes `:probe` for a suspended-entity attempt and
      # `:permanent` for a terminal one, or leaves it `nil` to let `OnDeliveryFailure`
      # classify transport-vs-response from the metadata. Guarded on `state ==
      # :scheduled` so a stale claimer can't record onto a row another pass finalized.
      log_class_arg =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :log_failure_class,
          type: :atom,
          allow_nil?: true
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :record_failure,
          accept: [:last_error, :delivery_metadata, :next_attempt_at, :terminal_reason],
          require_atomic?: false,
          arguments: [log_class_arg],
          changes: [
            guard_scheduled(),
            set_state(:failed),
            release_lease(),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Outbound.Delivery.Changes.OnDeliveryFailure
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_cancel_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :cancel) do
      dsl_state
    else
      # Deliberately NOT guarded to `:scheduled`: `:cancel` is multi-state —
      # coalescing supersedes `:pending` siblings (guarded `[:pending, :parked]` at
      # that call site), the `Reprocessor` cancels a skipped `:parked` row, and
      # an operator may cancel from the dashboard. Cancelling a `:scheduled` row just
      # frees its in-flight slot; there is no longer an Oban job to cancel.
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :cancel,
          accept: [:last_error],
          require_atomic?: false,
          changes: [set_state(:cancelled)]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_reprocess_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :reprocess) do
      dsl_state
    else
      # Resurrection back to `:pending` — a reprocessed `:parked` (rebuilt) or
      # `:failed` (operator "retry now", incl. a terminal head) row re-enters the
      # deliverable lifecycle, so `clear_claim()` wipes the lease/backoff bookkeeping
      # AND `terminal_reason`: a stale terminal verdict left on the row would silently
      # re-terminal it on its first retryable failure. `guard_reprocessable()` refuses
      # the transition on an in-flight `:scheduled` row (only) so reprocessing can't
      # clear its lease and cause a duplicate delivery.
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :reprocess,
          accept: [:delivery, :body_hash, :last_error],
          require_atomic?: false,
          changes: [guard_reprocessable(), set_state(:pending), clear_claim()]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_expire_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :expire) do
      dsl_state
    else
      # The opt-in age-based give-up (`Health.sweep_expired/0`): stamp
      # `terminal_reason: :expired` on a still-retrying `:failed` row, taking it
      # terminal (never promoted again; lane blocked like any terminal head). The
      # caller pushes the `state == :failed and is_nil(terminal_reason)` precondition
      # into the query (as the scheduler does for `:schedule`/`:suppress`), keeping
      # the action atomic-executable so the sweep is one bulk UPDATE — through Ash,
      # so `updated_at` bumps and host notifiers fire (unlike raw SQL).
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :expire,
          accept: [],
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: :terminal_reason, value: :expired]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_park_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :park) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :park,
          accept: [:delivery, :last_error],
          require_atomic?: false,
          changes: [set_state(:parked)]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_reset_to_pending_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :reset_to_pending) do
      dsl_state
    else
      # Park a `:scheduled` delivery back to `:pending` (suspension halt, or operator
      # recourse). Guarded on `state == :scheduled` so a stale claimer can't reset a
      # row another pass already delivered/cancelled. Clears the lease/backoff so the
      # scheduler's next promote starts clean. No Oban job to cancel anymore.
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :reset_to_pending,
          accept: [],
          require_atomic?: false,
          changes: [guard_scheduled(), set_state(:pending), clear_claim()]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp set_state(value) do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: {Change.SetAttribute, [attribute: :state, value: value]}
    )
  end

  defp set_delivered_at do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: {Change.SetAttribute, [attribute: :delivered_at, value: &DateTime.utc_now/0]}
    )
  end

  # Precondition filter: the update only matches a row still in `:scheduled`. On a
  # non-atomic update an unmatched filter makes the write a clean no-op (stale
  # error), never a resurrect — the relay's fence against a stale claimer.
  defp guard_scheduled do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: AshIntegration.Outbound.Delivery.Changes.GuardScheduled
    )
  end

  # Precondition filter for `:reprocess`: the update matches any row that is not
  # in-flight (`state != :scheduled`). Blocks a reprocess of a `:scheduled` row, whose
  # lease-clearing would otherwise cause a duplicate delivery, while still allowing
  # the legitimate `:pending`/`:parked`/`:failed` sources.
  defp guard_reprocessable do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: AshIntegration.Outbound.Delivery.Changes.GuardReprocessable
    )
  end

  # Clear the relay's lease + backoff bookkeeping AND the terminal verdict (used
  # when a row (re-)enters the deliverable lifecycle) so it doesn't inherit a stale
  # `claimed_at`/`next_attempt_at`/`terminal_reason`.
  defp clear_claim do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: AshIntegration.Outbound.Delivery.Changes.ClearClaim
    )
  end

  # Release the soft lease (`claimed_at → nil`) on a recorded failure so the durable
  # `next_attempt_at` backoff — not the lease — governs when the row is re-claimed.
  defp release_lease do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: AshIntegration.Outbound.Delivery.Changes.ReleaseLease
    )
  end

  # ── Code interface ──────────────────────────────────────────────────────

  defp add_code_interface_if_not_exists(dsl_state) do
    existing_names =
      dsl_state
      |> Transformer.get_entities([:code_interface])
      |> MapSet.new(& &1.name)

    defines = [
      {:create, [action: :create]},
      {:read_all, [action: :read]},
      {:schedule, [action: :schedule]},
      {:deliver, [action: :deliver]},
      {:suppress, [action: :suppress]},
      {:record_failure, [action: :record_failure]},
      {:cancel, [action: :cancel]},
      {:reprocess, [action: :reprocess]},
      {:destroy, [action: :destroy]}
    ]

    # Add each interface only when the host hasn't already defined one of that name,
    # so a host overriding a single `define` doesn't get the whole set re-added on
    # top (a duplicate-name DSL error). See the matching note in the Event transformer.
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

  # ── Identity (idempotency) ──────────────────────────────────────────────

  # One delivery per (event, subscription). A passive DB backstop for idempotent
  # dispatch: materialization and the `dispatched_at` stamp commit in ONE
  # transaction, so a rolled-back batch leaves no partial rows and a committed event
  # is never re-claimed (`claim/1` filters `dispatched_at IS NULL`). The constraint
  # is belt-and-suspenders — there is no skip-on-conflict code path.
  defp add_unique_delivery_identity_if_not_exists(dsl_state) do
    existing =
      dsl_state
      |> Transformer.get_entities([:identities])
      |> Enum.find(&(&1.name == :unique_event_subscription))

    if existing do
      dsl_state
    else
      {:ok, identity} =
        Transformer.build_entity(Dsl, [:identities], :identity,
          name: :unique_event_subscription,
          keys: [:event_id, :subscription_id]
        )

      Transformer.add_entity(dsl_state, [:identities], identity, type: :append)
    end
  end

  # ── Postgres references & indexes ───────────────────────────────────────

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

  defp add_partial_unique_index_if_not_exists(dsl_state) do
    index_name = "idx_one_scheduled_per_connection_event_key"

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
          fields: [:connection_id, :event_key],
          unique: true,
          # The lane invariant: at most ONE active head per lane, where "active" =
          # in-flight (`:scheduled`) OR held-waiting/terminal (`:failed`). This makes
          # per-key ordering a hard DB guarantee — a younger row cannot be promoted
          # (or its failure recorded) while an older one holds the lane, and a
          # terminal `:failed` head blocks its lane forever. See
          # `design/delivery-retry-model.md` §5.
          where: "state IN ('scheduled', 'failed')"
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  # Serves the delivery relay's claim — `WHERE state = 'scheduled' … ORDER BY
  # event_id … FOR UPDATE SKIP LOCKED`, partitioned by connection — without scanning
  # delivered/cancelled history. Partial on the in-flight frontier (normally small);
  # leads with `connection_id` (the batch/partition key) then `event_id` (the FIFO
  # claim order).
  defp add_delivery_claim_index_if_not_exists(dsl_state) do
    index_name = "idx_event_deliveries_delivery_claim"

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
          fields: [:connection_id, :event_id],
          where: "state = 'scheduled'"
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  # Serves the content-suppression baseline lookup (`Dedup.last_delivered_hash/1`):
  # the newest `:delivered` row strictly older than the head on its
  # `(subscription_id, event_key)` lane —
  #
  #   WHERE subscription_id = $1 AND event_key = $2 AND state = 'delivered'
  #     AND event_id < $3 ORDER BY event_id DESC LIMIT 1 (SELECT body_hash)
  #
  # run once per suppression-eligible head on every scheduler pass. Leading the
  # equality columns then `event_id` last makes the range + `ORDER BY event_id DESC
  # LIMIT 1` a single backward index scan; the existing `(subscription_id,
  # event_key, state)` index would have to sort the matched rows. Partial on
  # `state = 'delivered'` (the only baseline) keeps it off delivered/cancelled
  # history, and `INCLUDE (body_hash)` — the lone selected column — makes it an
  # index-only scan, no heap fetch.
  defp add_dedup_baseline_index_if_not_exists(dsl_state) do
    index_name = "idx_event_deliveries_dedup_baseline"

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
          fields: [:subscription_id, :event_key, :event_id],
          where: "state = 'delivered'",
          include: ["body_hash"]
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  defp add_schedulable_lane_index_if_not_exists(dsl_state) do
    index_name = "idx_event_deliveries_schedulable_lane"

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
          fields: [:connection_id, :event_key, :event_id],
          # Lane-head selection scans the schedulable pool: fresh (`:pending`),
          # build-parked (`:parked`), and waiting-to-retry/terminal (`:failed`). The
          # scheduler picks the oldest per lane and gates it on eligibility.
          where: "state IN ('pending', 'parked', 'failed')"
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end
end
