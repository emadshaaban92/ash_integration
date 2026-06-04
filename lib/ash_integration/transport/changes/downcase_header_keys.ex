defmodule AshIntegration.Transport.Changes.DowncaseHeaderKeys do
  @moduledoc false
  # Canonicalizes a transport config's `headers` map to lowercase keys on write.
  #
  # HTTP and Kafka header names are case-insensitive, but the delivery pipeline
  # carries them as a plain `{name, value}` list and de-dups case-insensitively
  # keeping the last entry. A connection-configured header whose case differs from
  # the library's wire headers (always lowercase) or from a transform override
  # would otherwise survive as a case-variant duplicate and be resolved
  # nondeterministically (by map key order) at delivery. Forcing the stored keys
  # to lowercase makes the canonical key the one authors see in the preview and
  # the only one that can collide — so overrides land deterministically.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :headers) do
      {:ok, headers} when is_map(headers) ->
        Ash.Changeset.force_change_attribute(changeset, :headers, downcase_keys(headers))

      _ ->
        changeset
    end
  end

  defp downcase_keys(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)
  end
end
