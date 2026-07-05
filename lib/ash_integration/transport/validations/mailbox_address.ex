defmodule AshIntegration.Transport.Validations.MailboxAddress do
  @moduledoc """
  Validates that a mailbox-bearing field (`from`, `user_id`) is a plausible
  email/UPN and, crucially, free of path/query metacharacters and control chars.

  The Microsoft Graph app-only send builds a `/users/{mailbox}/sendMail` URL from
  these values; a `/`, `?`, `#`, whitespace, or a control character would let a
  hostile mailbox rewrite the request path/query across the `.default`-scoped
  Graph surface. The send path already reserved-safe-encodes the mailbox, but this
  rejects such values at the config boundary too (defense-in-depth, and a readable
  error instead of a silently mangled address). Mirrors the resolver's
  `reject_control_chars` boundary style.

  Options:

    * `:field` — the attribute to validate (required).
    * `:allow_display_name?` — when `true`, accept the `"Display Name <addr>"`
      form and validate only the `<addr>` part (the display name may legitimately
      contain spaces). Defaults to `false` (the whole value is validated).
  """
  use Ash.Resource.Validation

  # `/ ? #` are the URL path/query/fragment delimiters; whitespace and C0/DEL
  # control chars are never valid in an address and are header-injection/
  # request-splitting vectors. `<` `>` can't appear in a bare mailbox.
  @invalid ~r/[\s\/?#<>\x00-\x1f\x7f]/

  # Splits a `"Display Name <addr@host>"` sender into its address part.
  @display_name_form ~r/\A\s*.*?\s*<([^>]+)>\s*\z/

  @impl true
  def validate(changeset, opts, _context) do
    field = opts[:field]

    case Ash.Changeset.get_attribute(changeset, field) do
      # Presence is enforced separately by `allow_nil?`; nothing to check here.
      nil ->
        :ok

      value when is_binary(value) ->
        value
        |> address_part(opts[:allow_display_name?])
        |> validate_address(field)

      _other ->
        {:error, field: field, message: "must be a string"}
    end
  end

  defp address_part(value, true) do
    case Regex.run(@display_name_form, value) do
      [_, address] -> String.trim(address)
      _ -> String.trim(value)
    end
  end

  defp address_part(value, _allow_display_name?), do: String.trim(value)

  defp validate_address("", field),
    do: {:error, field: field, message: "must be a valid email address"}

  defp validate_address(address, field) do
    if Regex.match?(@invalid, address) do
      {:error,
       field: field,
       message: "must be a valid email address (no spaces, control, or '/ ? #' characters)"}
    else
      :ok
    end
  end
end
