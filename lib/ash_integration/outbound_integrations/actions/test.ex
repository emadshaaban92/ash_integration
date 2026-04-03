defmodule AshIntegration.OutboundIntegrations.Actions.Test do
  use Ash.Resource.Actions.Implementation

  alias AshIntegration.OutboundIntegrations.Info
  alias AshIntegration.{EventDataLoader, LuaSandbox}

  @impl true
  def run(input, _opts, context) do
    outbound_integration_id = Ash.ActionInput.get_argument(input, :outbound_integration_id)
    action_arg = Ash.ActionInput.get_argument(input, :action)

    with {:ok, outbound_integration} <-
           Ash.get(AshIntegration.outbound_integration_resource(), outbound_integration_id,
             actor: context.actor,
             authorize?: true,
             load: [:owner]
           ),
         {:ok, action} <- resolve_action(outbound_integration.actions, action_arg),
         {:ok, sample_resource_id} <-
           find_sample_resource_id(
             outbound_integration.owner,
             outbound_integration.resource,
             action
           ),
         {:ok, data} <-
           EventDataLoader.load_event_data(
             outbound_integration.resource,
             sample_resource_id,
             action,
             outbound_integration.schema_version,
             outbound_integration.owner
           ) do
      event_data =
        Info.build_event(%{
          id: Ash.UUIDv7.generate(),
          resource: outbound_integration.resource,
          action: action,
          schema_version: outbound_integration.schema_version,
          occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          data: data
        })

      case LuaSandbox.execute(outbound_integration.transform_script, event_data) do
        {:ok, :skip} ->
          {:ok, %{input: event_data, output: nil, skipped: true, error: nil}}

        {:ok, payload} ->
          {:ok, %{input: event_data, output: payload, skipped: false, error: nil}}

        {:error, lua_error} ->
          {:ok, %{input: event_data, output: nil, skipped: false, error: lua_error}}
      end
    else
      {:error, :invalid_action} ->
        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             Ash.Error.Changes.InvalidArgument.exception(
               field: :action,
               message: "is not a configured action for this integration"
             )
           ]
         )}

      {:error, reason} when is_binary(reason) ->
        {:ok, %{input: nil, output: nil, skipped: false, error: reason}}

      {:error, reason} ->
        {:ok, %{input: nil, output: nil, skipped: false, error: humanize_error(reason)}}
    end
  end

  defp resolve_action(actions, nil), do: first_action(actions)

  defp resolve_action(actions, action) do
    if action in actions, do: {:ok, action}, else: {:error, :invalid_action}
  end

  defp first_action([action | _]), do: {:ok, action}
  defp first_action(_), do: {:error, :invalid_action}

  defp find_sample_resource_id(owner, resource_identifier, action) do
    with resource_module when not is_nil(resource_module) <-
           Info.resource_module(resource_identifier),
         loader when not is_nil(loader) <- Info.loader(resource_module) do
      if function_exported?(loader, :sample_resource_id, 2) do
        loader.sample_resource_id(owner, Info.action_atom(resource_module, action))
      else
        {:error,
         "No sample data available — implement sample_resource_id/2 or create test records"}
      end
    else
      _ -> {:error, "No loader configured for this resource"}
    end
  end

  defp humanize_error(atom) when is_atom(atom) do
    atom |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize_error(other), do: inspect(other)
end
