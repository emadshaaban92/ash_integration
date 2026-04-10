defmodule AshIntegration.OutboundIntegrationEventResource.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.{Dsl, Info}
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
     |> add_attribute_if_not_exists(:resource, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:action, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:resource_id, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:occurred_at, :utc_datetime_usec,
       allow_nil?: false,
       public?: true
     )
     |> add_attribute_if_not_exists(:snapshot, :map, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:payload, :map, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:state, :atom,
       allow_nil?: false,
       public?: true,
       default: :pending,
       constraints: [one_of: [:pending, :scheduled, :delivered, :cancelled]]
     )
     |> add_attribute_if_not_exists(:last_error, :string, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:delivery_metadata, :map, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:attempts, :integer,
       allow_nil?: false,
       public?: true,
       default: 0
     )
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_update_timestamp_if_not_exists(:updated_at)
     |> add_outbound_integration_relationship_if_not_exists()
     |> add_outbound_integration_logs_relationship_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_create_action_if_not_exists()
     |> add_next_pending_action_if_not_exists()
     |> add_for_outbound_integration_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_older_than_action_if_not_exists()
     |> add_stale_pending_action_if_not_exists()
     |> add_schedule_action_if_not_exists()
     |> add_deliver_action_if_not_exists()
     |> add_record_attempt_error_action_if_not_exists()
     |> add_cancel_action_if_not_exists()
     |> add_reprocess_action_if_not_exists()
     |> add_reset_to_pending_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_reference_if_not_exists(:outbound_integration,
       on_delete: :delete,
       on_update: :restrict
     )
     |> add_index_if_not_exists([:outbound_integration_id, :state])
     |> add_index_if_not_exists([:outbound_integration_id, :resource_id, :state])
     |> add_index_if_not_exists([:state, :updated_at])
     |> add_index_if_not_exists([:outbound_integration_id])
     |> add_partial_unique_index_if_not_exists()}
  end

  # ── Attributes ──────────────────────────────────────────────────────────

  defp add_primary_key_if_not_exists(dsl_state) do
    if Info.attribute(dsl_state, :id) do
      dsl_state
    else
      {:ok, pk} = Transformer.build_entity(Dsl, [:attributes], :uuid_v7_primary_key, name: :id)
      Transformer.add_entity(dsl_state, [:attributes], pk, type: :prepend)
    end
  end

  defp add_attribute_if_not_exists(dsl_state, name, type, opts) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      opts =
        opts
        |> Keyword.put(:name, name)
        |> Keyword.put(:type, type)

      {:ok, attribute} = Transformer.build_entity(Dsl, [:attributes], :attribute, opts)
      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  defp add_create_timestamp_if_not_exists(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(Dsl, [:attributes], :create_timestamp,
          name: name,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  defp add_update_timestamp_if_not_exists(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(Dsl, [:attributes], :update_timestamp,
          name: name,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  # ── Relationships ───────────────────────────────────────────────────────

  defp add_outbound_integration_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :outbound_integration) do
      dsl_state
    else
      outbound_integration_resource = AshIntegration.outbound_integration_resource()

      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :outbound_integration,
          destination: outbound_integration_resource,
          domain: AshIntegration.domain(),
          allow_nil?: false,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_outbound_integration_logs_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :outbound_integration_logs) do
      dsl_state
    else
      log_resource = AshIntegration.outbound_integration_log_resource()

      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :has_many,
          name: :outbound_integration_logs,
          destination: log_resource,
          destination_attribute: :outbound_integration_event_id,
          domain: AshIntegration.domain()
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  # ── Defaults ────────────────────────────────────────────────────────────

  defp add_default_accept_if_not_set(dsl_state) do
    case Transformer.get_option(dsl_state, [:actions], :default_accept) do
      nil ->
        Transformer.set_option(dsl_state, [:actions], :default_accept, [])

      _ ->
        dsl_state
    end
  end

  defp add_defaults_if_not_set(dsl_state) do
    existing_defaults =
      Transformer.get_option(dsl_state, [:actions], :defaults) || []

    has_read? =
      Enum.any?(existing_defaults, fn
        :read -> true
        {:read, _} -> true
        _ -> false
      end)

    has_destroy? =
      Enum.any?(existing_defaults, fn
        :destroy -> true
        {:destroy, _} -> true
        _ -> false
      end)

    defaults_to_add =
      if(has_read?, do: [], else: [:read]) ++
        if has_destroy?, do: [], else: [:destroy]

    case defaults_to_add do
      [] ->
        dsl_state

      additions ->
        Transformer.set_option(
          dsl_state,
          [:actions],
          :defaults,
          existing_defaults ++ additions
        )
    end
  end

  # ── Create Action ───────────────────────────────────────────────────────

  defp add_create_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :create) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :create,
          name: :create,
          primary?: true,
          accept: [
            :resource,
            :action,
            :resource_id,
            :occurred_at,
            :snapshot,
            :payload,
            :state,
            :last_error,
            :outbound_integration_id
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Read Actions ────────────────────────────────────────────────────────

  defp add_next_pending_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :next_pending) do
      dsl_state
    else
      import Ash.Expr

      integration_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :outbound_integration_id,
          type: :uuid,
          allow_nil?: false
        )

      resource_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :resource_id,
          type: :string,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter:
            expr(
              outbound_integration_id == ^arg(:outbound_integration_id) and
                resource_id == ^arg(:resource_id) and
                state == :pending
            )
        )

      prepare =
        Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
          preparation: {Ash.Resource.Preparation.Build, [sort: [id: :asc], limit: 1]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :next_pending,
          arguments: [integration_id_arg, resource_id_arg],
          filters: [filter],
          preparations: [prepare]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_for_outbound_integration_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :for_outbound_integration) do
      dsl_state
    else
      import Ash.Expr

      argument =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :outbound_integration_id,
          type: :uuid,
          allow_nil?: false
        )

      state_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :state,
          type: :atom,
          allow_nil?: true,
          constraints: [one_of: [:pending, :scheduled, :delivered, :cancelled]]
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter: expr(outbound_integration_id == ^arg(:outbound_integration_id))
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
          name: :for_outbound_integration,
          arguments: [argument, state_arg],
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

  defp add_older_than_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :older_than) do
      dsl_state
    else
      import Ash.Expr

      argument =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :days,
          type: :integer,
          allow_nil?: false,
          default: 90
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter:
            expr(
              state in [:delivered, :cancelled] and
                updated_at < ago(^arg(:days), :day)
            )
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :older_than,
          arguments: [argument],
          filters: [filter]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_stale_pending_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :stale_pending) do
      dsl_state
    else
      import Ash.Expr

      argument =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :outbound_integration_id,
          type: :uuid,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter:
            expr(
              outbound_integration_id == ^arg(:outbound_integration_id) and
                state == :pending and
                is_nil(payload)
            )
        )

      prepare =
        Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
          preparation: {Ash.Resource.Preparation.Build, [sort: [id: :asc]]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :stale_pending,
          arguments: [argument],
          filters: [filter],
          preparations: [prepare]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Update Actions (state transitions) ──────────────────────────────────

  defp add_schedule_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :schedule) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :schedule,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Ash.Resource.Change.SetAttribute, [attribute: :state, value: :scheduled]}
            ),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Changes.InsertDeliveryJob
            )
          ]
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
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Ash.Resource.Change.SetAttribute, [attribute: :state, value: :delivered]}
            ),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Changes.OnDeliverySuccess
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_record_attempt_error_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :record_attempt_error) do
      dsl_state
    else
      import Ash.Expr

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :record_attempt_error,
          accept: [:last_error, :delivery_metadata],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change:
                {Ash.Resource.Change.Atomic, [attribute: :attempts, expr: expr(attempts + 1)]}
            ),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Changes.OnDeliveryFailure
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
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :cancel,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Ash.Resource.Change.SetAttribute, [attribute: :state, value: :cancelled]}
            ),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Changes.CancelDeliveryJob
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_reprocess_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :reprocess) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :reprocess,
          accept: [:payload, :last_error],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Ash.Resource.Change.SetAttribute, [attribute: :state, value: :pending]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_reset_to_pending_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :reset_to_pending) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :reset_to_pending,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Ash.Resource.Change.SetAttribute, [attribute: :state, value: :pending]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Code Interface ──────────────────────────────────────────────────────

  defp add_code_interface_if_not_exists(dsl_state) do
    existing =
      dsl_state
      |> Transformer.get_entities([:code_interface])

    has_define? = Enum.any?(existing, &(&1.name == :create))

    if has_define? do
      dsl_state
    else
      defines = [
        {:create, [action: :create]},
        {:read_all, [action: :read]},
        {:next_pending, [action: :next_pending, args: [:outbound_integration_id, :resource_id]]},
        {:schedule, [action: :schedule]},
        {:deliver, [action: :deliver]},
        {:record_attempt_error, [action: :record_attempt_error]},
        {:cancel, [action: :cancel]},
        {:reprocess, [action: :reprocess]},
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

  # ── Indexes & References ────────────────────────────────────────────────

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
        Transformer.build_entity(
          AshPostgres.DataLayer,
          [:postgres, :custom_indexes],
          :index,
          fields: fields
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  defp add_partial_unique_index_if_not_exists(dsl_state) do
    index_name = "idx_one_scheduled_per_integration_resource"

    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.find(&(&1.name == index_name))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(
          AshPostgres.DataLayer,
          [:postgres, :custom_indexes],
          :index,
          name: index_name,
          fields: [:outbound_integration_id, :resource_id],
          unique: true,
          where: "state = 'scheduled'"
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end
end
