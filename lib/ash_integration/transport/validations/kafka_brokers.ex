defmodule AshIntegration.Transport.Validations.KafkaBrokers do
  @moduledoc false
  # Create/update validation for a Kafka `brokers` list: reject an entry that
  # isn't a `host` or `host:port` with an integer port AT SAVE TIME, rather than
  # letting it save cleanly and crash at delivery.
  #
  # `Utils.parse_brokers/1` calls `String.to_integer/1` on the port segment, so a
  # saved broker like `"kafka.internal:abc"` (or `"host:99999"`, `"host:1:2"`)
  # raises `ArgumentError` when the first event is delivered — a crash *outside*
  # the transport's classified-error taxonomy, so the delivery neither classifies
  # nor suspends cleanly. The broker list is static, operator-pasted data, so it is
  # checked once here with the same host/port shape `parse_brokers/1` will parse.
  # Mirrors `Validations.CacertPem`.
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # Stay cheap when brokers aren't changing (e.g. a parent update touching other
    # fields).
    if Ash.Changeset.changing_attribute?(changeset, :brokers) do
      brokers = Ash.Changeset.get_attribute(changeset, :brokers) || []

      case Enum.find(brokers, &invalid_broker?/1) do
        nil -> :ok
        bad -> {:error, field: :brokers, message: message(bad)}
      end
    else
      :ok
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "broker host:port parsing runs outside the data layer"}

  # The accept criteria mirror `Utils.parse_brokers/1`: split on the first colon,
  # so a `host` alone is fine (port defaults to 9092) and a `host:port` must carry
  # an integer port in the valid TCP range. A bare host must be non-empty.
  defp invalid_broker?(broker) when is_binary(broker) do
    case String.split(broker, ":", parts: 2) do
      [host] -> host == ""
      [host, port] -> host == "" or not valid_port?(port)
    end
  end

  defp invalid_broker?(_broker), do: true

  defp valid_port?(port) do
    case Integer.parse(port) do
      {number, ""} -> number >= 1 and number <= 65_535
      _ -> false
    end
  end

  defp message(bad) do
    "broker #{inspect(bad)} is not a valid \"host\" or \"host:port\" — the port must " <>
      "be an integer between 1 and 65535"
  end
end
