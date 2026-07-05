defmodule AshIntegration.Transport.Validations.EgressUrl do
  @moduledoc """
  Rejects a URL that the SSRF egress policy would block at save time.

  Runs the `field`'s value through `AshIntegration.Transport.Egress.classify/1`
  and fails the changeset when the host resolves to a non-public address
  (`:blocked`) or the URL is malformed (`:invalid`) — the same guard delivery
  applies to webhook URLs, surfaced early so an operator can't persist an
  obviously-unreachable/SSRF token endpoint.

  A `:unresolvable` host (transient DNS) is intentionally allowed through: like
  the delivery resolver, that is a connectivity condition, not an authoring
  error, and the send-time `Egress.pin/1` re-check is the real gate. A blank
  value is left to the presence/format validations.
  """
  use Ash.Resource.Validation

  alias AshIntegration.Transport.Egress

  @impl true
  def validate(changeset, opts, _context) do
    field = opts[:field]

    case Ash.Changeset.get_attribute(changeset, field) do
      value when is_binary(value) and value != "" ->
        check(field, value)

      _ ->
        :ok
    end
  end

  defp check(field, value) do
    case Egress.classify(value) do
      :ok -> :ok
      {:error, :unresolvable, _message} -> :ok
      {:error, _category, message} -> {:error, field: field, message: message}
    end
  end
end
