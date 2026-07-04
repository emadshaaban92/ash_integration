defmodule AshIntegration.Connection.Transformer do
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
     |> add_attribute_if_not_exists(:name, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:transport_config, AshIntegration.Transport.TransportConfig,
       allow_nil?: false,
       public?: true
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
     |> add_attribute_if_not_exists(:suspension_reason, :string,
       allow_nil?: true,
       public?: true
     )
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_update_timestamp_if_not_exists(:updated_at)
     |> add_subscriptions_relationship_if_not_exists()
     |> add_deliveries_relationship_if_not_exists()
     |> add_owner_relationship_if_not_exists()
     |> add_parked_aggregates_if_not_exists()
     |> add_identity_if_not_exists(:name, [:name])
     |> add_activate_action_if_not_exists()
     |> add_deactivate_action_if_not_exists()
     |> add_suspend_action_if_not_exists()
     |> add_unsuspend_action_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_create_action_if_not_exists()
     |> add_update_action_if_not_exists()
     |> add_by_id_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_reference_if_not_exists(:owner, on_delete: :restrict, on_update: :restrict)
     |> add_index_if_not_exists([:active])
     |> add_index_if_not_exists([:owner_id])}
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

  defp add_subscriptions_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :subscriptions) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :has_many,
          name: :subscriptions,
          destination_attribute: :connection_id,
          destination: AshIntegration.subscription_resource(),
          domain: AshIntegration.domain()
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  # Destination is EventDelivery (per-subscription delivery state), not the Event
  # outbox — hence `:deliveries`.
  defp add_deliveries_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :deliveries) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :has_many,
          name: :deliveries,
          destination_attribute: :connection_id,
          destination: AshIntegration.event_delivery_resource(),
          domain: AshIntegration.domain()
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_owner_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :owner) do
      dsl_state
    else
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :owner,
          destination: AshIntegration.actor_resource(),
          allow_nil?: false,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  # Standing parked-backlog health across all of the connection's subscriptions
  # (`ParkedHealth`): `parked_count` (count of `:parked` deliveries) +
  # `oldest_parked_at` (min `created_at` of them). Query-time aggregates filtered to
  # `state == :parked`; added-if-not-exists so hosts can override. The connection's
  # parked health is purely visible/alertable — the opt-in parked-suspend acts on
  # subscriptions, never the connection.
  defp add_parked_aggregates_if_not_exists(dsl_state) do
    dsl_state
    |> add_parked_count_aggregate_if_not_exists()
    |> add_oldest_parked_at_aggregate_if_not_exists()
  end

  defp add_parked_count_aggregate_if_not_exists(dsl_state) do
    if Info.aggregate(dsl_state, :parked_count) do
      dsl_state
    else
      {:ok, aggregate} =
        Transformer.build_entity(Dsl, [:aggregates], :count,
          name: :parked_count,
          relationship_path: :deliveries,
          filter: [state: :parked],
          public?: true
        )

      Transformer.add_entity(dsl_state, [:aggregates], aggregate, type: :append)
    end
  end

  defp add_oldest_parked_at_aggregate_if_not_exists(dsl_state) do
    if Info.aggregate(dsl_state, :oldest_parked_at) do
      dsl_state
    else
      {:ok, aggregate} =
        Transformer.build_entity(Dsl, [:aggregates], :min,
          name: :oldest_parked_at,
          relationship_path: :deliveries,
          field: :created_at,
          filter: [state: :parked],
          public?: true
        )

      Transformer.add_entity(dsl_state, [:aggregates], aggregate, type: :append)
    end
  end

  defp add_identity_if_not_exists(dsl_state, name, keys) do
    existing = dsl_state |> Info.identities() |> Enum.find(&(&1.name == name))

    if existing do
      dsl_state
    else
      {:ok, identity} =
        Transformer.build_entity(Dsl, [:identities], :identity, name: name, keys: keys)

      Transformer.add_entity(dsl_state, [:identities], identity, type: :append)
    end
  end

  # ── Suspension / health actions ─────────────────────────────────────────

  defp add_activate_action_if_not_exists(dsl_state) do
    add_set_attr_update(dsl_state, :activate, :active, true)
  end

  defp add_deactivate_action_if_not_exists(dsl_state) do
    add_set_attr_update(dsl_state, :deactivate, :active, false)
  end

  defp add_set_attr_update(dsl_state, action_name, attribute, value) do
    if Info.action(dsl_state, action_name) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: action_name,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: attribute, value: value]}
            )
          ]
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
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: :suspended, value: true]}
            ),
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
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change:
                {AshIntegration.Outbound.Delivery.Changes.EmitResumeTelemetry,
                 event: [:ash_integration, :connection, :unsuspended]}
            )
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

  # ── CRUD actions / defaults ─────────────────────────────────────────────

  @standard_accept [:name, :owner_id, :transport_config]

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

  defp add_code_interface_if_not_exists(dsl_state) do
    existing = Transformer.get_entities(dsl_state, [:code_interface])

    if Enum.any?(existing, &(&1.name == :create)) do
      dsl_state
    else
      defines = [
        {:create, [action: :create]},
        {:read_all, [action: :read]},
        {:by_id, [action: :by_id, args: [:id]]},
        {:update, [action: :update]},
        {:destroy, [action: :destroy]},
        {:activate, [action: :activate]},
        {:deactivate, [action: :deactivate]},
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
