defmodule AshIntegration.OutboundIntegrationLogResource.Transformer do
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
     |> add_attribute_if_not_exists(:schema_version, :integer, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:resource_id, :uuid, allow_nil?: false, public?: true)
     |> add_attribute_if_not_exists(:request_payload, :map, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:response_status, :integer, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:response_body, :string, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:error_message, :string, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:kafka_offset, :integer, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:kafka_partition, :integer, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:duration_ms, :integer, allow_nil?: true, public?: true)
     |> add_attribute_if_not_exists(:status, :atom,
       allow_nil?: false,
       public?: true,
       constraints: [one_of: [:success, :failed, :skipped]]
     )
     |> add_create_timestamp_if_not_exists(:created_at)
     |> add_relationship_if_not_exists()
     |> add_event_relationship_if_not_exists()
     |> add_default_accept_if_not_set()
     |> add_defaults_if_not_set()
     |> add_create_action_if_not_exists()
     |> add_older_than_action_if_not_exists()
     |> add_for_integration_action_if_not_exists()
     |> add_index_action_if_not_exists()
     |> add_code_interface_if_not_exists()
     |> add_reference_if_not_exists(:integration,
       on_delete: :delete,
       on_update: :restrict
     )
     |> add_index_if_not_exists([:integration_id])
     |> add_index_if_not_exists([:event_id])
     |> add_index_if_not_exists([:created_at])
     |> add_index_if_not_exists([:integration_id, :resource_id, :created_at])}
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

  defp add_primary_key_if_not_exists(dsl_state) do
    if Info.attribute(dsl_state, :id) do
      dsl_state
    else
      {:ok, pk} = Transformer.build_entity(Dsl, [:attributes], :uuid_v7_primary_key, name: :id)
      Transformer.add_entity(dsl_state, [:attributes], pk, type: :prepend)
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

  defp add_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :integration) do
      dsl_state
    else
      outbound_integration_resource = AshIntegration.outbound_integration_resource()

      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :integration,
          destination: outbound_integration_resource,
          domain: AshIntegration.domain(),
          allow_nil?: false,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_event_relationship_if_not_exists(dsl_state) do
    if Info.relationship(dsl_state, :event) do
      dsl_state
    else
      event_resource = AshIntegration.outbound_integration_event_resource()

      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :event,
          destination: event_resource,
          domain: AshIntegration.domain(),
          allow_nil?: true,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    end
  end

  defp add_create_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :create) do
      dsl_state
    else
      accept = [
        :resource,
        :action,
        :schema_version,
        :resource_id,
        :request_payload,
        :response_status,
        :response_body,
        :error_message,
        :kafka_offset,
        :kafka_partition,
        :duration_ms,
        :status,
        :integration_id,
        :event_id
      ]

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :create,
          name: :create,
          primary?: true,
          accept: accept
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
          filter: expr(created_at < ago(^arg(:days), :day))
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

  defp add_for_integration_action_if_not_exists(dsl_state) do
    if Info.action(dsl_state, :for_integration) do
      dsl_state
    else
      import Ash.Expr

      argument =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :integration_id,
          type: :uuid,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter: expr(integration_id == ^arg(:integration_id))
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
          name: :for_integration,
          arguments: [argument],
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
      search_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :search,
          type: :string
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
        {:read_all, [action: :read]}
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
