defmodule AshIntegration.OutboundIntegrations.Loader do
  @moduledoc """
  Behaviour for loading and transforming outbound integration event data.

  Implementors provide four callbacks:

  - `load_resource/3` — loads the Ash resource record from the database with
    the appropriate relationships for building the event payload. Called with
    `actor` for authorization.

  - `build_sample_resource/2` — builds an in-memory Ash struct with realistic
    sample data populated in all relationships. This struct is NOT persisted.
    The library will automatically filter out relationships the actor cannot
    access (via `Ash.can?`) before passing it to `transform_event_data/3`.

    Takes `schema_version` and `action` so the sample can vary by action
    (e.g., a `:delete` action might only populate minimal fields).

  - `transform_event_data/3` — pure function that transforms an Ash resource
    record (real or sample) into the event data map. This is the single source
    of truth for the event payload shape. It must handle `nil` relationships
    gracefully (e.g., when the actor cannot access related data).

  - `sample_resource_id/2` — finds a real record ID for the Test action.

  Loaders do NOT need to know about authorization filtering. The library
  handles it transparently: `build_sample_resource/2` returns a full struct,
  the library nils out unauthorized relationships, and `transform_event_data/3`
  receives the filtered struct — exactly like it would receive a real record
  where Ash policies blocked certain relationships.
  """

  @doc """
  Loads the resource record from the database with all relationships needed
  for the event payload.

  Called with the actor (integration owner) for Ash authorization.
  Should use `Ash.get` or `Ash.read` with appropriate `:load` options.
  """
  @callback load_resource(
              resource_id :: term(),
              schema_version :: integer(),
              actor :: term()
            ) ::
              {:ok, Ash.Resource.record()} | {:error, term()}

  @doc """
  Builds an in-memory Ash struct with sample data for all relationships.

  This struct should look like a fully-loaded resource record with realistic
  fake data in ALL relationships. The library will automatically nil out
  relationships the actor cannot access before passing it to
  `transform_event_data/3`.

  The struct should be the same Ash resource type as what `load_resource/3`
  returns, with relationships populated as Ash structs (not plain maps).

  Takes `action` so the sample can vary by action type — for example, a
  `:delete` action might only need the resource ID and timestamps, while a
  `:create` action includes the full record with all relationships.
  """
  @callback build_sample_resource(schema_version :: integer(), action :: atom()) ::
              Ash.Resource.record()

  @doc """
  Transforms a loaded resource record into the event data map.

  This is a pure data transformation — no database access, no authorization.
  It receives either a real record (from `load_resource/3`) or a filtered
  sample record (from `build_sample_resource/2` after authorization filtering).

  Must handle `nil` / `%Ash.NotLoaded{}` relationships gracefully, as they
  indicate data the actor cannot access.
  """
  @callback transform_event_data(
              resource :: Ash.Resource.record(),
              action :: atom(),
              schema_version :: integer()
            ) :: map()

  @doc """
  Finds a sample resource ID for the Test action.

  Called with the actor for authorization. Should return the ID of a real
  record that the actor can access, or `{:error, :no_sample_resource}`.
  """
  @callback sample_resource_id(actor :: term(), action :: atom()) ::
              {:ok, term()} | {:error, term()}
end
