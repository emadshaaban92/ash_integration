defmodule AshIntegration.Outbound.Delivery.Validations.TransformSource do
  @moduledoc false
  # Create/update validation: reject a `transform_source` that can't be saved, at
  # save time, with a readable field error — rather than letting a broken script
  # reach dispatch and PARK every delivery for the subscription. Two layers, both
  # only when `transform_source` is actually changing:
  #
  #   1. STATIC (`Runtime.validate/2`): the runtime's own cheap, side-effect-
  #      free check — size + parse for Lua; a real module-validation for a future
  #      WASM guest. Runs first; needs no event sample.
  #   2. SMOKE (`Preview.smoke/2`): run the script against the producer's
  #      `example/1` and reject it if it raises, hits a denied `io`/`os` call,
  #      `nil`-indexes, or returns a non-table. This catches the large class that
  #      is syntactically valid but cannot run — exactly what parse can't see. It
  #      stops before the wire descriptor / SSRF egress (dispatch-time concerns),
  #      and no-ops when the producer declares no `example/1`.
  #
  # A nil/blank script is a no-op transform and always valid. The smoke layer can
  # only catch failures that manifest on the example; a script that passes here
  # can still fail on a real event of a *different shape* — that residual is what
  # dispatch's park/reprocess remains for.
  use Ash.Resource.Validation

  alias AshIntegration.Outbound.Delivery.Transform.Preview
  alias AshIntegration.Outbound.Delivery.Transform.Runtime

  @impl true
  def validate(changeset, _opts, _context) do
    # Stay cheap on health updates (suspend/record_success/…): only check when the
    # script itself is changing.
    if Ash.Changeset.changing_attribute?(changeset, :transform_source) do
      validate_script(changeset)
    else
      :ok
    end
  end

  # The check is pure Elixir (it calls into the runtime's validator), so it can't
  # be expressed as an atomic SQL expression; fall back to a regular validation.
  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "transform script validation runs in the transform runtime"}

  defp validate_script(changeset) do
    case value(changeset, :transform_source) do
      script when is_binary(script) and script != "" ->
        # Static check first (cheap, no sample); only smoke-run if it parses.
        with :ok <- check(Runtime.validate(runtime(changeset), script)) do
          check(smoke(changeset))
        end

      # nil/blank → no-op transform, nothing to validate.
      _ ->
        :ok
    end
  end

  # Run the script against the producer's `example/1`, mirroring dispatch's
  # pre-seed. Builds an in-memory preview record from the changeset (nothing is
  # persisted) and loads the referenced connection for its transport defaults.
  # A genuine transform failure comes back as `{:error, _}` from the runtime and
  # blocks the save; anything the harness itself can't set up (no connection
  # yet, an unrelated invalid attribute, …) must NOT block the save, so it
  # degrades to `:ok` — the static check above already ran.
  defp smoke(changeset) do
    with {:ok, preview} <- Ash.Changeset.apply_attributes(changeset, force?: true),
         {:ok, connection} <- load_connection(preview.connection_id) do
      Preview.smoke(preview, connection)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp load_connection(nil), do: :error

  defp load_connection(connection_id),
    do: Ash.get(AshIntegration.connection_resource(), connection_id, authorize?: false)

  defp check(:ok), do: :ok
  defp check({:error, message}), do: {:error, field: :transform_source, message: message}

  defp runtime(changeset) do
    case value(changeset, :transform_runtime) do
      runtime when is_atom(runtime) and not is_nil(runtime) -> runtime
      _ -> Runtime.default_runtime()
    end
  end

  defp value(changeset, attribute) do
    case Map.fetch(changeset.attributes, attribute) do
      {:ok, value} -> value
      :error -> Map.get(changeset.data, attribute)
    end
  end
end
