defmodule AshIntegration.Inbound.Declare.Info do
  @moduledoc """
  Introspection helpers for the `inbound_commands` DSL
  (`AshIntegration.Inbound.Declare.Commands`).

  Command types are stored verbatim as declared and exposed here as their
  canonical (downcased) **string** form — never interned to an atom (no
  `String.to_atom` on declared/DB/wire values). Normalization happens once, here,
  so the registry's keys and the core's wire-normalized lookups match exactly.
  """

  alias AshIntegration.Inbound.Declare.Dsl.Command

  @doc """
  True if the resource carries the `AshIntegration.Inbound.Declare.Commands`
  extension (checks for the extension module itself, not merely the section).
  """
  def commands?(resource) do
    AshIntegration.Inbound.Declare.Commands in extensions(resource)
  end

  defp extensions(resource) do
    Spark.Dsl.Extension.get_persisted(resource, :extensions, [])
  rescue
    _ -> []
  end

  @doc "All `command` entities declared on the resource (or DSL state)."
  def commands(resource_or_dsl) do
    Spark.Dsl.Extension.get_entities(resource_or_dsl, [:inbound_commands])
  end

  @doc "The canonical (downcased string) command type of a `command` entity."
  def command_type(%Command{type: type}), do: type |> to_string() |> String.downcase()

  @doc "The verbatim declared command type (pre-normalization), for error messages."
  def raw_command_type(%Command{type: type}), do: to_string(type)

  @doc "The Ash action name (atom) a `command` applies through."
  def action(%Command{action: action}), do: action

  @doc "The handler module for a `command`."
  def handler(%Command{handler: handler}), do: handler
end
