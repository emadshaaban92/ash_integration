defmodule AshIntegration.Outbound.Delivery.Reprocessor do
  @moduledoc """
  Operator-triggered recovery for parked deliveries.

  The `EventDelivery` `reprocess` action is only a state-setter. The actual re-run
  lives here: it re-derives the wire descriptor **from the immutable `Event`**
  (never re-loading the source), re-running the producer's `project/3` for the
  delivery's subscription and then the transform — so a corrected `project` OR a
  corrected transform both unblock the lane.
  """
  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Resolver
  alias AshIntegration.Outbound.Wire.Envelope
  alias AshIntegration.Outbound.Delivery.Scheduler
  alias AshIntegration.Outbound.Declare.Registry

  @doc """
  Re-run one delivery from its immutable Event.

  Returns `{:ok, :pending}` when it becomes deliverable (scheduler notified),
  `{:ok, :cancelled}` when `project`/transform skip it, or `{:error, reason}` when
  it still fails (stays parked) or can't be reprocessed.
  """
  def reprocess_event(delivery) do
    delivery = Ash.load!(delivery, [:event, :subscription, :connection], authorize?: false)

    cond do
      is_nil(delivery.subscription) -> {:error, :no_subscription}
      is_nil(delivery.connection) -> {:error, :no_connection}
      is_nil(delivery.event) -> {:error, :no_event}
      true -> rerun(delivery)
    end
  end

  @doc """
  Reprocess every parked delivery for a connection. Returns
  `%{reprocessed: n, failed: n}`.
  """
  def reprocess_parked_for_connection(connection_id) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(connection_id == ^connection_id and state == :parked)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(%{reprocessed: 0, failed: 0}, fn delivery, acc ->
      case reprocess_event(delivery) do
        {:ok, _state} -> %{acc | reprocessed: acc.reprocessed + 1}
        {:error, _reason} -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp rerun(%{event: event} = delivery) do
    case Registry.producer_for(event.event_type) do
      nil ->
        park!(delivery, "No producer registered for event type #{event.event_type}", :project)
        {:error, :no_producer}

      producer ->
        rerun(delivery, producer)
    end
  end

  defp rerun(delivery, producer) do
    %{event: event, subscription: subscription, connection: connection} = delivery

    case project_decision(producer, event, subscription) do
      {:skip, reason} ->
        update!(delivery, :cancel, %{last_error: "Skipped: #{inspect(reason)}"})
        {:ok, :cancelled}

      # A `project` raise is a code bug, not a deliberate skip — re-park (mirrors
      # dispatch) so a fix-and-reprocess can still recover it, rather than
      # cancelling it terminally.
      {:error, reason} ->
        park!(delivery, "project error: #{reason}", :project)
        {:error, reason}

      {:deliver, data} ->
        run_transform(
          delivery,
          connection,
          subscription,
          envelope(event, data),
          event.created_at
        )
    end
  end

  defp run_transform(delivery, connection, subscription, envelope, created_at) do
    case Resolver.resolve(connection, subscription, envelope, created_at) do
      :skip ->
        update!(delivery, :cancel, %{last_error: "Skipped by transform"})
        {:ok, :cancelled}

      {:ok, resolved, body_hash} ->
        update!(delivery, :reprocess, %{delivery: resolved, body_hash: body_hash, last_error: nil})

        Scheduler.notify()
        {:ok, :pending}

      {:error, lua_error} ->
        park!(delivery, "Transform error: #{lua_error}", :transform)
        {:error, lua_error}
    end
  end

  # Re-run project for this single (event, subscription) so redaction/authz
  # changes take effect on reprocess. Fail-closed; a raise returns `{:error, _}`
  # so the caller can re-park (a code bug), distinct from a deliberate `{:skip}`.
  defp project_decision(producer, event, subscription) do
    decisions = producer.project([event], [subscription], %{})

    case Map.get(decisions, event.id, {:skip, "unauthorized"}) do
      :deliver ->
        {:deliver, event.data}

      {:deliver, projected} when is_map(projected) ->
        {:deliver, projected}

      {:skip, reason} ->
        {:skip, reason}

      {:per_subscription, by_sub} when is_map(by_sub) ->
        per_subscription(by_sub, subscription, event)

      other ->
        invalid_decision!(other)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp per_subscription(by_sub, subscription, event) do
    case Map.get(by_sub, subscription.id, {:skip, "unauthorized"}) do
      :deliver -> {:deliver, event.data}
      {:deliver, projected} when is_map(projected) -> {:deliver, projected}
      {:skip, reason} -> {:skip, reason}
      other -> invalid_decision!(other)
    end
  end

  # A non-map projection or unknown decision shape is a producer bug. Raise a
  # descriptive error; the `rescue` above turns it into `{:error, _}`, so the
  # delivery is re-parked (fail-closed, recoverable) rather than shipping full
  # data or crashing — matching the dispatch path.
  defp invalid_decision!(other) do
    raise ArgumentError, "project returned an invalid decision: #{inspect(other)}"
  end

  defp envelope(event, data) do
    Envelope.transform_input(%{
      id: event.id,
      type: event.event_type,
      version: event.version,
      event_key: event.event_key,
      created_at: event.created_at,
      subject: event.source_resource_id,
      data: data
    })
  end

  # Re-park and re-emit `:parked` (mirrors the dispatch-time park in `Specs`).
  defp park!(delivery, reason, failure_kind) do
    update!(delivery, :park, %{delivery: nil, last_error: reason})

    :telemetry.execute(
      [:ash_integration, :delivery, :parked],
      %{count: 1},
      %{
        event_id: delivery.event_id,
        event_type: delivery.event_type,
        event_key: delivery.event_key,
        subscription_id: delivery.subscription_id,
        connection_id: delivery.connection_id,
        reason: reason,
        failure_kind: failure_kind
      }
    )
  end

  defp update!(delivery, action, params) do
    delivery
    |> Ash.Changeset.for_update(action, params, authorize?: false)
    |> Ash.update!(authorize?: false)
  end
end
