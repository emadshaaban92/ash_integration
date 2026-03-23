defmodule AshIntegration.OutboundIntegrationResource.Transformer do
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
     |> add_attribute_if_not_exists(:resource, :string, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:actions, {:array, :string},
       allow_nil?: false,
       public?: true,
       default: []
     )
     |> add_attribute_if_not_exists(:schema_version, :integer,
       allow_nil?: false,
       public?: true
     )
     |> add_attribute_if_not_exists(:transport, :atom,
       allow_nil?: false,
       public?: true,
       default: :http,
       constraints: [one_of: [:http]]
     )
     |> add_attribute_if_not_exists(:transport_config, AshIntegration.HttpConfig,
       allow_nil?: false,
       public?: true
     )
     |> add_attribute_if_not_exists(:transform_script, :string,
       allow_nil?: false,
       public?: true,
       constraints: [max_length: 10_240]
     )
     |> add_attribute_if_not_exists(:consecutive_failures, :integer,
       allow_nil?: false,
       public?: true,
       default: 0
     )
     |> add_attribute_if_not_exists(:deactivation_reason, :atom,
       allow_nil?: true,
       public?: true,
       constraints: [one_of: [:manual, :delivery_failures]]
     )
     |> add_attribute_if_not_exists(:active, :boolean,
       default: true,
       public?: true,
       always_select?: true
     )
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_update_timestamp_if_not_exists(:updated_at)
     |> add_delivery_logs_relationship_if_not_exists()
     |> add_owner_relationship_if_not_exists()
     |> add_identity_if_not_exists(:name, [:name])
     |> add_activate_action_if_not_exists()
     |> add_deactivate_action_if_not_exists()
     |> add_record_success_action_if_not_exists()
     |> add_record_failure_action_if_not_exists()
     |> add_auto_deactivate_action_if_not_exists()
     |> add_outbound_config_validation_if_not_exists()
     |> add_test_action_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_create_action_if_not_exists()
     |> add_update_action_if_not_exists()
     |> add_by_id_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_reference_if_not_exists(:owner, on_delete: :restrict, on_update: :restrict)
     |> add_index_if_not_exists([:resource, :active])
     |> add_index_if_not_exists([:owner_id])}
  end

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

  defp add_delivery_logs_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :delivery_logs) do
      dsl_state
    else
      delivery_log_resource = AshIntegration.delivery_log_resource()

      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :has_many,
          name: :delivery_logs,
          destination: delivery_log_resource,
          domain: AshIntegration.domain()
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_owner_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :owner) do
      dsl_state
    else
      actor_resource = AshIntegration.actor_resource()

      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :owner,
          destination: actor_resource,
          allow_nil?: false,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_identity_if_not_exists(dsl_state, name, keys) do
    existing =
      dsl_state
      |> Info.identities()
      |> Enum.find(&(&1.name == name))

    if existing do
      dsl_state
    else
      {:ok, identity} =
        Transformer.build_entity(Dsl, [:identities], :identity,
          name: name,
          keys: keys
        )

      Transformer.add_entity(dsl_state, [:identities], identity, type: :append)
    end
  end

  defp add_activate_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :activate) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :activate,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: :active, value: true]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_deactivate_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :deactivate) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :deactivate,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: :active, value: false]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_record_success_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :record_success) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :record_success,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: :consecutive_failures, value: 0]}
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
      import Ash.Expr

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :record_failure,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change:
                {Change.Atomic,
                 [attribute: :consecutive_failures, expr: expr(consecutive_failures + 1)]}
            ),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: AshIntegration.Changes.AutoDeactivateOnFailures
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_auto_deactivate_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :auto_deactivate) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :auto_deactivate,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: :active, value: false]}
            ),
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change:
                {Change.SetAttribute,
                 [attribute: :deactivation_reason, value: :delivery_failures]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_outbound_config_validation_if_not_exists(dsl_state) do
    existing =
      dsl_state
      |> Transformer.get_entities([:validations])
      |> Enum.any?(fn v ->
        match?(%{validation: {AshIntegration.Validations.OutboundConfig, _}}, v) or
          match?(%{validation: AshIntegration.Validations.OutboundConfig}, v)
      end)

    if existing do
      dsl_state
    else
      {:ok, validation} =
        Transformer.build_entity(Dsl, [:validations], :validate,
          validation: AshIntegration.Validations.OutboundConfig,
          on: [:create, :update]
        )

      Transformer.add_entity(dsl_state, [:validations], validation, type: :append)
    end
  end

  defp add_test_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :test) do
      dsl_state
    else
      outbound_integration_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :action], :argument,
          name: :outbound_integration_id,
          type: :uuid,
          allow_nil?: false
        )

      action_arg =
        Transformer.build_entity!(Dsl, [:actions, :action], :argument,
          name: :action,
          type: :string
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :action,
          name: :test,
          returns: :map,
          arguments: [outbound_integration_id_arg, action_arg],
          run: AshIntegration.OutboundIntegrations.Actions.Test
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  @standard_accept [
    :name,
    :resource,
    :actions,
    :schema_version,
    :owner_id,
    :transport,
    :transport_config,
    :transform_script
  ]

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
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :by_id,
          get_by: [:id]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_index_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :index) do
      dsl_state
    else
      search_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :search,
          type: :string
        )

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
        {:by_id, [action: :by_id, args: [:id]]},
        {:update, [action: :update]},
        {:destroy, [action: :destroy]},
        {:activate, [action: :activate]},
        {:deactivate, [action: :deactivate]},
        {:record_success, [action: :record_success]},
        {:record_failure, [action: :record_failure]},
        {:auto_deactivate, [action: :auto_deactivate]},
        {:test, [action: :test, args: [:outbound_integration_id]]}
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
end
