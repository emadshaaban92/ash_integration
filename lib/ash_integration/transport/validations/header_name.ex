defmodule AshIntegration.Transport.Validations.HeaderName do
  @moduledoc false
  # Reject a header name containing a C0 control character (`\x00-\x1f`) or DEL
  # (`\x7f`) at save time.
  #
  # A configured header name (api-key `header_name`, stripe signing `header_name`)
  # is injected VERBATIM into the outbound request. A CR/LF smuggled into the name
  # splits the request (header injection), and Mint raises on such a name — which
  # would crash-loop the delivery OUTSIDE the transport failure taxonomy. This is
  # the same trust-boundary check the `custom` signing scheme already applies to
  # its script-built headers at send time (`Signing`'s `reject_control_chars`),
  # lifted to save time so the bad value never reaches delivery at all.
  use Ash.Resource.Validation

  # C0 control characters and DEL. Kept in sync with `Signing.reject_control_chars/2`.
  @control_chars ~r/[\x00-\x1f\x7f]/

  @impl true
  def validate(changeset, opts, _context) do
    field = opts[:field]

    case Ash.Changeset.get_attribute(changeset, field) do
      value when is_binary(value) ->
        if String.match?(value, @control_chars) do
          {:error, field: field, message: "must not contain control characters"}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "header-name control-char validation runs a regex"}
end
