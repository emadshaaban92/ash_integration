defmodule AshIntegration.Outbound.Delivery.Validations.SubscriptionRoute do
  @moduledoc false
  # Create/update validation: a subscription's `route_config` variant must match
  # its connection's transport type — an HTTP route on an HTTP connection, a Kafka
  # route on a Kafka connection. The `route_config` union already constrains the
  # value to a known transport; this just rejects a mismatch against the connection
  # (e.g. a Kafka route on an HTTP connection), which would otherwise be a dead
  # config silently ignored at delivery. A nil `route_config` is fine — the
  # transport falls back to the connection's defaults.
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # Stay cheap on health updates (suspend/unsuspend/…): only consult the
    # connection when `route_config` is actually changing.
    if Ash.Changeset.changing_attribute?(changeset, :route_config) do
      validate_against_connection(changeset)
    else
      :ok
    end
  end

  # Loading the connection is a DB read, so this can't run atomically; fall back
  # to a regular validation rather than failing to compile on atomic actions.
  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "route validation must read the connection's transport type"}

  defp validate_against_connection(changeset) do
    case value(changeset, :route_config) do
      %Ash.Union{type: route_type} ->
        check_match(route_type, connection_type(value(changeset, :connection_id)))

      # nil → defaults; the `connection_id` belongs_to constraint covers a missing
      # connection.
      _ ->
        :ok
    end
  end

  defp check_match(route_type, {:ok, route_type}), do: :ok

  defp check_match(route_type, {:ok, connection_type}) do
    {:error,
     field: :route_config,
     message: "is a #{route_type} route, but the connection's transport is #{connection_type}"}
  end

  # No resolvable connection yet — don't double up on the belongs_to error.
  defp check_match(_route_type, :error), do: :ok

  defp connection_type(nil), do: :error

  defp connection_type(connection_id) do
    case Ash.get(AshIntegration.connection_resource(), connection_id, authorize?: false) do
      {:ok, %{transport_config: %Ash.Union{type: type}}} -> {:ok, type}
      _ -> :error
    end
  end

  defp value(changeset, attribute) do
    case Map.fetch(changeset.attributes, attribute) do
      {:ok, value} -> value
      :error -> Map.get(changeset.data, attribute)
    end
  end
end
