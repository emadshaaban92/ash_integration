defmodule AshIntegration.Outbound.Delivery.Subscription.Transformer do
  @moduledoc false
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
     # The transform mutates a PRE-SEEDED, transport-shaped `result` (body,
     # headers, routing) — see `AshIntegration.Outbound.Delivery.Resolver`. It is
     # OPTIONAL: a nil/blank script is a no-op that sends the resolved defaults, so
     # the attribute is nilable (Ash's string cast trims "" to nil) and the
     # resolver treats nil as an empty script.
     |> add_attribute_if_not_exists(:transform_script, :string,
       allow_nil?: true,
       public?: true,
       constraints: [max_length: 10_240]
     )
     |> add_attribute_if_not_exists(:notify_on_every_change, :boolean,
       default: false,
       public?: true,
       always_select?: true
     )
     # ── Per-route transport config (resolved against the connection's defaults
     #    at delivery) ──────────────────────────────────────────────────────
     # A transport-tagged union (HTTP: path/method/timeout; Kafka: topic) mirroring
     # the connection's `transport_config`. Its variant must match the connection's
     # transport type (SubscriptionRoute validation). Nil → all defaults (HTTP:
     # POST the base URL; Kafka: the connection's default topic). New transports add
     # a union variant rather than new nullable columns.
     |> add_attribute_if_not_exists(
       :route_config,
       AshIntegration.Outbound.Delivery.Route.RouteConfig,
       allow_nil?: true,
       public?: true
     )
     |> add_attribute_if_not_exists(:consecutive_failures, :integer,
       allow_nil?: false,
       public?: true,
       default: 0
     )
     |> add_attribute_if_not_exists(:active, :boolean,
       default: true,
       public?: true,
       always_select?: true
     )
     |> add_attribute_if_not_exists(:suspended, :boolean,
       default: false,
       public?: true,
       always_select?: true
     )
     |> add_attribute_if_not_exists(:suspended_at, :utc_datetime_usec,
       allow_nil?: true,
       public?: true
     )
     |> add_attribute_if_not_exists(:suspension_reason, :string, allow_nil?: true, public?: true)
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_update_timestamp_if_not_exists(:updated_at)
     |> add_connection_relationship_if_not_exists()
     |> add_events_relationship_if_not_exists()
     |> add_activate_action_if_not_exists()
     |> add_deactivate_action_if_not_exists()
     |> add_record_success_action_if_not_exists()
     |> add_suspend_action_if_not_exists()
     |> add_unsuspend_action_if_not_exists()
     |> add_event_type_validation_if_not_exists()
     |> add_route_validation_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_create_action_if_not_exists()
     |> add_update_action_if_not_exists()
     |> add_by_id_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_for_connection_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_reference_if_not_exists(:connection, on_delete: :delete, on_update: :restrict)
     |> add_index_if_not_exists([:connection_id])
     |> add_index_if_not_exists([:event_type])
     |> add_index_if_not_exists([:connection_id, :event_type, :version])}
  end

  # ── Attributes ──────────────────────────────────────────────────────────

  defp add_primary_key_if_not_exists(dsl_state) do
    if Info.attribute(dsl_state, :id) do
      dsl_state
    else
      # DB-generated UUIDv7 (Postgres `uuidv7()`), not app-generated — the
      # database owns id minting. `generated?: true` keeps it out of inserts and
      # reads it back via RETURNING.
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

  defp add_events_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :events) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :has_many,
          name: :events,
          destination_attribute: :subscription_id,
          destination: AshIntegration.event_delivery_resource(),
          domain: AshIntegration.domain()
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  # ── Suspension / health actions ─────────────────────────────────────────

  defp add_activate_action_if_not_exists(dsl_state),
    do: add_set_attr_update(dsl_state, :activate, :active, true)

  defp add_deactivate_action_if_not_exists(dsl_state),
    do: add_set_attr_update(dsl_state, :deactivate, :active, false)

  defp add_record_success_action_if_not_exists(dsl_state),
    do: add_set_attr_update(dsl_state, :record_success, :consecutive_failures, 0)

  defp add_set_attr_update(dsl_state, action_name, attribute, value) do
    if Info.action(dsl_state, action_name) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: action_name,
          accept: [],
          require_atomic?: false,
          changes: [set_change(attribute, value)]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_suspend_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :suspend) do
      dsl_state
    else
      reason_arg =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :reason,
          type: :string,
          allow_nil?: true
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :suspend,
          accept: [],
          require_atomic?: false,
          arguments: [reason_arg],
          changes: [
            set_change(:suspended, true),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Outbound.Delivery.Changes.SetSuspensionDetails
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_unsuspend_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :unsuspend) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :unsuspend,
          accept: [],
          require_atomic?: false,
          changes: [
            set_change(:suspended, false),
            set_change(:suspended_at, nil),
            set_change(:suspension_reason, nil),
            set_change(:consecutive_failures, 0)
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp set_change(attribute, value) do
    Transformer.build_entity!(Dsl, [:actions, :update], :change,
      change: {Change.SetAttribute, [attribute: attribute, value: value]}
    )
  end

  # ── Validations ─────────────────────────────────────────────────────────

  @event_type_validation AshIntegration.Outbound.Delivery.Validations.SubscriptionEventType

  # Reject a subscription whose `(event_type, version)` is not in the derived
  # catalog. Applies to all create/update actions; it early-outs when neither
  # attribute is changing, so it stays cheap on health updates.
  defp add_event_type_validation_if_not_exists(dsl_state) do
    already? =
      dsl_state
      |> Transformer.get_entities([:validations])
      |> Enum.any?(fn v ->
        match?(%{validation: {@event_type_validation, _}}, v) or
          match?(%{validation: @event_type_validation}, v)
      end)

    if already? do
      dsl_state
    else
      {:ok, validation} =
        Transformer.build_entity(Dsl, [:validations], :validate,
          validation: @event_type_validation
        )

      Transformer.add_entity(dsl_state, [:validations], validation, type: :append)
    end
  end

  @route_validation AshIntegration.Outbound.Delivery.Validations.SubscriptionRoute

  # Reject a `route_config` whose transport variant doesn't match the connection's
  # transport type. Cheap: early-outs unless `route_config` is changing.
  defp add_route_validation_if_not_exists(dsl_state) do
    add_module_validation_if_not_exists(dsl_state, @route_validation)
  end

  defp add_module_validation_if_not_exists(dsl_state, module) do
    already? =
      dsl_state
      |> Transformer.get_entities([:validations])
      |> Enum.any?(fn v ->
        match?(%{validation: {^module, _}}, v) or match?(%{validation: ^module}, v)
      end)

    if already? do
      dsl_state
    else
      {:ok, validation} =
        Transformer.build_entity(Dsl, [:validations], :validate, validation: module)

      Transformer.add_entity(dsl_state, [:validations], validation, type: :append)
    end
  end

  # ── CRUD actions / defaults ─────────────────────────────────────────────

  @standard_accept [
    :event_type,
    :version,
    :transform_script,
    :notify_on_every_change,
    :route_config,
    :connection_id
  ]

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

  defp add_create_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :create) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :create,
          name: :create,
          primary?: true,
          accept: @standard_accept
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_update_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :update) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :update,
          primary?: true,
          require_atomic?: false,
          accept: @standard_accept
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_by_id_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :by_id) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read, name: :by_id, get_by: [:id])

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_index_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :index) do
      dsl_state
    else
      search_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument, name: :search, type: :string)

      pagination =
        Transformer.build_entity!(Dsl, [:actions, :read], :pagination,
          keyset?: true,
          offset?: true,
          default_limit: 20,
          countable: :by_default
        )

      prepare =
        Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
          preparation: {Ash.Resource.Preparation.Build, [sort: [id: :desc]]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :index,
          arguments: [search_arg],
          preparations: [prepare],
          pagination: pagination
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_for_connection_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :for_connection) do
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
          filter: expr(connection_id == ^arg(:connection_id))
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :for_connection,
          arguments: [argument],
          filters: [filter]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_code_interface_if_not_exists(dsl_state) do
    existing = Transformer.get_entities(dsl_state, [:code_interface])

    if Enum.any?(existing, &(&1.name == :create)) do
      dsl_state
    else
      defines = [
        {:create, [action: :create]},
        {:read_all, [action: :read]},
        {:by_id, [action: :by_id, args: [:id]]},
        {:for_connection, [action: :for_connection, args: [:connection_id]]},
        {:update, [action: :update]},
        {:destroy, [action: :destroy]},
        {:activate, [action: :activate]},
        {:deactivate, [action: :deactivate]},
        {:record_success, [action: :record_success]},
        {:suspend, [action: :suspend]},
        {:unsuspend, [action: :unsuspend]}
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
end
