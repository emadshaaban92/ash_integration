defmodule AshIntegration.Outbound.Wire.Envelope do
  @moduledoc """
  Builds the event-first wire envelope's **semantic headers**.

  The header set is transport-agnostic: it returns `{suffix, value}` pairs with
  no prefix, so each transport renders them with its own convention — `x-`
  prefixed on HTTP, bare on Kafka — keeping the suffixes identical so they
  map mechanically.

  The wire **leads with the event type**. Source fields (`source_resource`,
  `source_resource_id`, `source_action`) are stored on the event for internal
  audit/ops but are **never** emitted on the wire — the event type is the
  contract. These pairs pre-seed the transform's `result.headers` at dispatch (so
  they are developer-overridable/removable); the signature is added by
  `AshIntegration.Outbound.Delivery.Resolver` after the transform.
  """

  @doc """
  The canonical wire-metadata `{suffix, value}` pairs (no transport prefix) for a
  transform-input `envelope`.

  Deliberately minimal: only the three fields every consumer needs by default —
  `event-id` (idempotency/dedup), `event-type` (the routing/contract discriminator)
  and `event-version` (which schema to parse). Everything situational is opt-in via
  the Lua transform, which sees the full input envelope (see `transform_input/1`):

    * `created-at` — redundant on Kafka (the native record `ts`), informational on
      HTTP; add it in Lua if a consumer wants it.
    * `event-key` — an internal ordering/coalescing key. On Kafka it is already the
      native partition key (the message key, set independently of headers); on HTTP
      it carries no meaning (no ordering) and dedup should key on `event-id`.
    * `connection-id` — an internal UUID the consumer can't use; a leak, not a
      contract.

  Takes the same envelope map that pre-seeds the Lua transform rather than an
  `Event` struct, so dispatch can build the pre-seeded `result.headers` before the
  event row exists. Each transport renders these with its own convention — `x-`
  prefixed on HTTP, bare on Kafka.
  """
  def wire_pairs(envelope) do
    [
      {"event-id", to_string(envelope.id)},
      {"event-type", to_string(envelope.type)},
      {"event-version", to_string(envelope.version)}
    ]
  end

  @doc """
  The canonical **Lua transform input** envelope, built in ONE place so the
  dispatch-time and reprocess-time inputs can't drift.

  Leads with the event type and carries **no provenance** — `source_resource` /
  `source_resource_id` / `source_action` stay internal and are never exposed to
  the transform (the event type is the contract). Extra keys on `fields` (e.g. a
  stray `source`) are dropped. `created_at` is normalized to a canonical ISO8601
  string whether the caller passes a `DateTime` (from the Event's `created_at`) or
  a string, so the same event yields a byte-identical input on both the dispatch
  and reprocess paths.
  """
  def transform_input(fields) do
    %{
      id: fields.id,
      type: fields.type,
      version: fields.version,
      event_key: fields.event_key,
      created_at: iso8601(fields.created_at),
      subject: fields.subject,
      data: fields.data
    }
  end

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_iso8601(dt)
      {:error, _} -> value
    end
  end

  defp iso8601(other), do: to_string(other)
end
