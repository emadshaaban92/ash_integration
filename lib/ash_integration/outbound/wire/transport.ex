defmodule AshIntegration.Outbound.Wire.Transport do
  @moduledoc """
  Behaviour + dispatcher for event-first outbound transports.

  Each transport receives the **connection** (with its `transport_config`
  loaded) and the **event** (carrying the snapshot-at-dispatch `delivery`
  descriptor — the resolved, signed wire payload — plus the event-first metadata).
  The event **must have its `:subscription` loaded** (the HTTP transport still
  reads the per-route timeout live from it). Transports REPLAY `event.delivery`
  verbatim and inject only the live secret carve-out (HTTP auth), and return:

    * `{:ok, metadata}` on success;
    * `{:error, metadata}` on failure, where `metadata` carries a `failure_class`
      of `:transport` (couldn't reach the target) or `:response` (the target
      responded with a rejection) — the key that drives two-level suspension —
      plus `:error_message` and `:retryable`.

  Transport availability is resolved via
  `AshIntegration.Transport.Utils.available?/1`.
  """

  @type success :: %{optional(atom()) => term()}
  @type error :: %{
          required(:failure_class) => :transport | :response,
          required(:error_message) => String.t(),
          required(:retryable) => boolean(),
          optional(atom()) => term()
        }

  @callback deliver(connection :: struct(), event :: struct()) ::
              {:ok, success()} | {:error, error()}

  @typedoc """
  Per-row delivery outcome: each `EventDelivery.id` maps to its own result. A
  partial success (e.g. an HTTP 207, or a multi-row insert that rejects one row)
  reports each row independently, so the relay can record the right state /
  suspension class / poison counter / backoff per row — never wedging a batchmate
  nor marking a failed row delivered.
  """
  @type batch_results :: %{optional(term()) => {:ok, success()} | {:error, error()}}

  @doc """
  Optional batched send. Defaults (`deliver_batch/2` below) to one `deliver/2` per
  event, so a transport only implements it to actually coalesce the wire calls
  (CloudEvents batch-mode HTTP #36, a future multi-row DB insert). Kafka never
  implements it — `:brod`'s internal request-coalescing already gives wire
  efficiency while preserving per-message acks, and app-level batching there would
  add partial-failure demux risk for no gain. Must return one result per event id.
  """
  @callback deliver_batch(connection :: struct(), events :: [struct()]) :: batch_results()
  @optional_callbacks deliver_batch: 2

  @spec module_for(:http | :kafka) :: module()
  def module_for(:http), do: AshIntegration.Outbound.Wire.Transports.Http
  def module_for(:kafka), do: AshIntegration.Outbound.Wire.Transports.Kafka

  @doc """
  Deliver `event` to `connection` over its configured transport.
  """
  @spec deliver(struct(), struct()) :: {:ok, success()} | {:error, error()}
  def deliver(connection, event) do
    %Ash.Union{type: type} = connection.transport_config
    module_for(type).deliver(connection, event)
  end

  @doc """
  Deliver a batch of `events` to `connection`, returning a per-row result map keyed
  by `EventDelivery.id`.

  Every event in the batch shares one connection (the relay partitions by
  `connection_id` and never batches across connections). A transport that defines
  `deliver_batch/2` coalesces the wire calls and reports per row; otherwise this
  falls back to one `deliver/2` per event — the additive default that lets the
  delivery relay carry a real batch interface from day one while batchable
  transports land later (#36). The default impl preserves the at-least-once,
  per-row contract exactly: each row gets its own `{:ok, _}` / `{:error, _}`.
  """
  @spec deliver_batch(struct(), [struct()]) :: batch_results()
  def deliver_batch(connection, events) do
    %Ash.Union{type: type} = connection.transport_config
    module = module_for(type)

    if function_exported?(module, :deliver_batch, 2) do
      apply(module, :deliver_batch, [connection, events])
    else
      Map.new(events, fn event -> {event.id, module.deliver(connection, event)} end)
    end
  end
end
