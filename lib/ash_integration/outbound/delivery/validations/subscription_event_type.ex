defmodule AshIntegration.Outbound.Delivery.Validations.SubscriptionEventType do
  @moduledoc false
  # Create/update validation: a subscription's `(event_type, version)` must exist
  # in the derived catalog. Without this a typo (`prodct.created`) silently creates
  # a dead subscription that no dispatch ever matches.
  use Ash.Resource.Validation

  alias AshIntegration.Outbound.Declare.Registry

  @impl true
  def validate(changeset, _opts, _context) do
    # Only touch the catalog when the route's identity is actually changing —
    # health updates (`suspend`, `unsuspend`, …) leave these alone and must
    # stay cheap (no domain scan).
    if Ash.Changeset.changing_attribute?(changeset, :event_type) or
         Ash.Changeset.changing_attribute?(changeset, :version) do
      validate_pair(value(changeset, :event_type), value(changeset, :version))
    else
      :ok
    end
  end

  # Atomic actions can't consult the in-memory catalog; fall back to a regular
  # (non-atomic) validation rather than failing to compile on such actions.
  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "event-type validation must read the derived catalog"}

  # Absent values are reported by the `allow_nil?: false` attribute constraints;
  # don't double up with a confusing catalog message.
  defp validate_pair(nil, _version), do: :ok
  defp validate_pair(_event_type, nil), do: :ok

  defp validate_pair(event_type, version) do
    case Map.fetch(Registry.catalog(), event_type) do
      :error ->
        {:error, field: :event_type, message: "is not a known event type (#{event_type})"}

      {:ok, %{versions: versions}} ->
        if version in versions do
          :ok
        else
          supported = versions |> Enum.sort() |> Enum.join(", ")

          {:error,
           field: :version,
           message:
             "version #{version} is not supported for #{event_type} (supported: #{supported})"}
        end
    end
  end

  defp value(changeset, attribute) do
    case Map.fetch(changeset.attributes, attribute) do
      {:ok, value} -> value
      :error -> Map.get(changeset.data, attribute)
    end
  end
end
