defmodule AshIntegration.Outbound.Declare.Source.Info do
  @moduledoc """
  Introspection helpers for the `outbound_events` source-trigger DSL
  (`AshIntegration.Outbound.Declare.Source`).

  Event types are stored verbatim as declared and exposed here normalized to
  their canonical **string** form — never interned to an atom (no
  `String.to_atom` on declared/DB/wire values).
  """

  alias AshIntegration.Outbound.Declare.Dsl.Event

  @doc """
  True if the resource carries the `AshIntegration.Outbound.Declare.Source` extension.

  Checks for the extension module itself (not merely the presence of an
  `outbound_events` section), so detection stays robust if another extension
  ever introduces a same-named section.
  """
  def source?(resource) do
    AshIntegration.Outbound.Declare.Source in extensions(resource)
  end

  defp extensions(resource) do
    Spark.Dsl.Extension.get_persisted(resource, :extensions, [])
  rescue
    _ -> []
  end

  @doc """
  The external identifier stored as the Event's `source_resource` provenance.

  Optional in the DSL: defaults to the resource's `short_name`, so most resources
  need not declare it. An explicit `source_resource` pins provenance across module
  renames or matches an external system's naming.
  """
  def source_resource(resource) do
    case Spark.Dsl.Extension.get_opt(resource, [:outbound_events], :source_resource) do
      nil -> resource |> Ash.Resource.Info.short_name() |> to_string()
      value -> value
    end
  end

  @doc "All `event` entities declared on the resource."
  def events(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:outbound_events])
  end

  @doc "The canonical (string) event types declared on the resource."
  def event_types(resource) do
    resource |> events() |> Enum.map(&event_type/1) |> Enum.uniq()
  end

  @doc "The canonical string form of an `event`'s type (accepts the raw atom-or-string)."
  def event_type(%Event{type: type}), do: to_string(type)

  @doc "The Ash action names (atoms) declared for an `event`."
  def actions(%Event{actions: actions}), do: actions || []

  @doc "The producer module for an `event`."
  def producer(%Event{producer: producer}), do: producer

  @doc "Supported version numbers for an `event`, sorted ascending."
  def versions(%Event{versions: versions}) do
    versions |> Enum.map(& &1.number) |> Enum.sort()
  end

  @doc "The `event` entity on `resource` that declares `event_type`, or nil."
  def event(resource, event_type) when is_binary(event_type) do
    Enum.find(events(resource), &(event_type(&1) == event_type))
  end
end
