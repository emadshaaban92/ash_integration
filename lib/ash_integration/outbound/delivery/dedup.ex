defmodule AshIntegration.Outbound.Delivery.Dedup do
  @moduledoc false
  # Content-addressed delivery suppression (the `suppress_unchanged?` feature).
  #
  # Two concerns live here:
  #
  #   * `hash/1` — a CANONICAL hash of the dedup target (the per-subscription body,
  #     or the transform-set `dedup_on`). Canonical = recursively sorted map keys,
  #     so two equal maps that happen to iterate in different orders hash the same
  #     (an unstable hash would cost a spurious extra delivery — safe, but defeats
  #     the point). JSON encoding + SHA-256, hex-encoded. Computed at materialize and
  #     stored on the row's `body_hash` (only for `suppress_unchanged` subscriptions;
  #     nil otherwise). Raises on a non-encodable term; the Resolver parks it.
  #   * `last_delivered_hash/1` — the baseline lookup used by the **scheduler** when
  #     it promotes a lane head: the `body_hash` of the most recent **`:delivered`**
  #     row on this delivery's `(subscription_id, event_key)` lane, older than it.
  #     Only real sends are the baseline — a suppressed body always equals the last
  #     delivered one by construction, so suppressed rows never need to be the
  #     baseline (and `:delivered` stays the honest "bytes went out" signal). Stable
  #     at promote time: the lane has no in-flight row, so nothing newer has delivered.
  require Ash.Query

  @doc """
  Canonical SHA-256 (hex) of `term`. Deterministic across map key order. Raises
  `Protocol.UndefinedError`/`ArgumentError` for a term the canonical encoder can't
  serialize (only Lua-decoded shapes — maps, lists, strings, numbers, booleans,
  nil — are expected).
  """
  @spec hash(term()) :: String.t()
  def hash(term) do
    :sha256
    |> :crypto.hash(encode(term))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The dedup target for a resolved descriptor: the transform-set `dedup_on` when
  present and non-empty, else the transport body (`body` for HTTP, `value` for
  Kafka). Returns `nil` only when there is genuinely nothing to compare (no body),
  which hashes to a stable empty marker via `hash/1`.
  """
  @spec target(map(), term()) :: term()
  def target(descriptor, dedup_on)
  def target(_descriptor, dedup_on) when dedup_on not in [nil, %{}, []], do: dedup_on
  def target(%{"value" => value}, _dedup_on), do: value
  def target(%{"body" => body}, _dedup_on), do: body
  def target(_descriptor, _dedup_on), do: nil

  @doc """
  The `body_hash` of the newest `:delivered` row strictly older than `delivery` on
  its `(subscription_id, event_key)` lane, or `nil` when there is no such baseline
  (first delivery, or the baseline was reaped by retention — both deliver safely).
  """
  @spec last_delivered_hash(map()) :: String.t() | nil
  def last_delivered_hash(delivery) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(
      subscription_id == ^delivery.subscription_id and
        event_key == ^delivery.event_key and
        state == :delivered and
        event_id < ^delivery.event_id
    )
    |> Ash.Query.sort(event_id: :desc)
    |> Ash.Query.select([:body_hash])
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      row -> row.body_hash
    end
  end

  # ── Canonical encoder (sorted map keys; Jason for scalar/string escaping) ────

  defp encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))

    [
      ?{,
      pairs |> Enum.map(fn {k, v} -> [Jason.encode!(k), ?:, encode(v)] end) |> intersperse(?,),
      ?}
    ]
  end

  defp encode(list) when is_list(list) do
    [?[, list |> Enum.map(&encode/1) |> intersperse(?,), ?]]
  end

  # Scalars (strings, numbers, booleans, nil, atoms) go through Jason so string
  # escaping and number formatting match a normal JSON encode.
  defp encode(scalar), do: Jason.encode!(scalar)

  defp intersperse([], _sep), do: []
  defp intersperse([single], _sep), do: [single]
  defp intersperse([head | tail], sep), do: [head, sep | intersperse(tail, sep)]
end
