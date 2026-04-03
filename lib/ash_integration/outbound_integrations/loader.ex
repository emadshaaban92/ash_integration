defmodule AshIntegration.OutboundIntegrations.Loader do
  @moduledoc """
  Behaviour for loading and transforming outbound integration event data.

  ## Required callbacks

  - `load_resource/3` — loads the Ash resource record from the database with
    the appropriate relationships for building the event payload. Called with
    `actor` for authorization.

  - `transform_event_data/3` — pure function that transforms an Ash resource
    record (real or sample) into the event data map. This is the single source
    of truth for the event payload shape. It must handle `nil` relationships
    gracefully (e.g., when the actor cannot access related data).

  ## Optional callbacks

  - `sample_resource_id/2` — finds a real record ID to use for sample previews.
    When implemented, the library will load a real record for the preview,
    with Ash policies applied naturally through the actor.

  - `build_sample_resource/2` — builds an in-memory Ash struct with realistic
    sample data populated in all relationships. Used as a fallback when
    `sample_resource_id/2` is not implemented or finds no records. The library
    will automatically filter out relationships the actor cannot access before
    passing it to `transform_event_data/3`.

  ## Sample preview strategy

  The library tries to build a sample preview in this order:

  1. **Real record** — if `sample_resource_id/2` is implemented and returns an ID,
     load it via `load_resource/3`. Ash handles authorization naturally.
  2. **Synthetic sample** — if no real record is available and `build_sample_resource/2`
     is implemented, build a synthetic struct and filter unauthorized relationships.
  3. **Error** — if neither is available, return `{:error, :no_sample_data}`.
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

  Optional. Used as a fallback when `sample_resource_id/2` is not implemented
  or finds no records.

  The struct should look like a fully-loaded resource record with realistic
  fake data in ALL relationships. The library will automatically nil out
  relationships the actor cannot access before passing it to
  `transform_event_data/3`.

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
  Finds a real record ID to use for sample previews.

  Optional. When implemented, the library prefers loading a real record
  over building a synthetic sample. Called with the actor for authorization.
  Should return the ID of a record the actor can access, or an error tuple.
  """
  @callback sample_resource_id(actor :: term(), action :: atom()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks build_sample_resource: 2, sample_resource_id: 2
end
