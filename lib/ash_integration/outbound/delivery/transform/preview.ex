defmodule AshIntegration.Outbound.Delivery.Transform.Preview do
  @moduledoc """
  Operator-triggered **transform preview** for a saved subscription.

  It builds a sample event for the subscription's `(event_type, version)` and runs
  the subscription's Lua transform, returning the transform **input** and its
  **output** so an operator can see exactly what the transform produces. It is a
  pure, read-only preview: **nothing is delivered** — no transport call, no
  network, no `Event` row, no counters touched.

  The sample comes from the producer's `example/1`. There is no "load a real
  source record" preview: `produce/3` consumes in-memory `{changeset, record}`
  pairs a read-only preview can't synthesize, so `example/1` is the sample source.
  It falls back to an empty map when the producer declares no `example/1`.

  `run/2` returns `{:ok, result}` where `result.outcome` is one of:

    * `:ok` — the transform resolved a delivery descriptor (`result.output`, the
      transport-shaped wire payload incl. the resolved headers and body-as-map;
      the signature and auth are live carve-outs added at delivery, so they are
      NOT in this descriptor);
    * `:skipped` — the transform returned `result = nil` (`result.output` is `nil`);
    * `:error` — the transform raised or produced an invalid descriptor
      (`result.error`); `result.output` is `nil`.

  `result` also carries `:input` (the transform-input envelope) and `:source` (a
  map noting whether a real record or the static sample was used). Returns
  `{:error, :not_found}` when the subscription can't be read as `actor`.
  """
  alias AshIntegration.Outbound.Delivery.Resolver
  alias AshIntegration.Outbound.Wire.Envelope
  alias AshIntegration.Outbound.Declare.Registry

  @doc """
  Run a transform preview for `subscription` (a record or its id), authorized as
  `actor`. See the module doc for the result shape.
  """
  def run(subscription, actor) do
    id = subscription_id(subscription)

    case Ash.get(AshIntegration.subscription_resource(), id,
           actor: actor,
           load: [connection: [:owner]]
         ) do
      {:ok, subscription} -> run_loaded(subscription)
      {:error, _} -> {:error, :not_found}
    end
  end

  defp subscription_id(%{id: id}), do: id
  defp subscription_id(id) when is_binary(id), do: id

  @doc """
  Save-time **smoke gate** for a subscription's transform: run the script
  against the producer's `example/1` — exactly the same sample this preview uses
  — and report whether it executes cleanly. Wired into the create/update
  validation (see `AshIntegration.Outbound.Delivery.Validations.TransformSource`)
  so a script that raises on its own producer's example is rejected at save
  rather than parking every delivery for the subscription.

  `subscription` may be a persisted record or an unpersisted preview struct (the
  validation passes the latter); `connection` is the loaded connection record.

  Returns:

    * `:ok` — the transform produced a table or skipped on the example, **or**
      the producer declares no `example/1` (there is no representative sample to
      run against, so the cheaper parse-check stays the only floor — we don't
      fabricate a failure from an empty payload);
    * `{:error, message}` — the transform raised, hit a denied op, or returned a
      non-table on the example.

  Like `Resolver.smoke/4` (which it delegates to) this stops before `finalize`:
  it validates the script, not the wire descriptor or the egress policy.
  """
  def smoke(subscription, connection) do
    case producer_example(subscription) do
      nil ->
        :ok

      _example ->
        created_at = DateTime.utc_now()
        {input, _sample} = sample_envelope(subscription, created_at)
        Resolver.smoke(connection, subscription, input, created_at)
    end
  end

  defp run_loaded(subscription) do
    created_at = DateTime.utc_now()
    {input, sample} = sample_envelope(subscription, created_at)

    # Resolve the full transport-shaped descriptor (incl. the pre-seeded wire
    # headers the author can override/remove and the computed signature) exactly
    # as dispatch would, so the preview shows what will actually be sent.
    case Resolver.resolve(subscription.connection, subscription, input, created_at) do
      :skip ->
        {:ok, %{outcome: :skipped, input: input, output: nil, source: sample.source}}

      {:ok, delivery} ->
        {:ok, %{outcome: :ok, input: input, output: delivery, source: sample.source}}

      {:error, error} ->
        {:ok, %{outcome: :error, input: input, output: nil, error: error, source: sample.source}}
    end
  end

  # The sample transform-input envelope for `subscription`, built from the
  # producer's `example/1`. Shared by the operator preview and the save-time
  # smoke gate so both run against an identical input. Returns `{input, sample}`.
  defp sample_envelope(subscription, created_at) do
    sample = build_sample(subscription)

    input =
      Envelope.transform_input(%{
        # Preview-only synthetic id — this envelope never hits the database, so
        # app-side generation is fine here (real Events get DB-generated ids).
        id: Ash.UUIDv7.generate(),
        type: subscription.event_type,
        version: subscription.version,
        event_key: sample.event_key,
        created_at: created_at,
        subject: sample.subject,
        data: sample.data
      })

    {input, sample}
  end

  # The sample payload comes from the producer's `example/1` (it mirrors
  # `produce/3`'s output). `produce/3` consumes `{changeset, record}` pairs, which
  # a read-only preview can't synthesize, so `example/1` is the sample source.
  # Falls back to an empty map when the producer declares no `example/1`.
  defp build_sample(subscription) do
    data = producer_example(subscription) || %{}

    %{
      source: %{real?: false},
      data: data,
      event_key: to_string(event_key(subscription, data)),
      subject: "test-subject-id"
    }
  end

  defp producer_example(subscription) do
    with producer when not is_nil(producer) <- Registry.producer_for(subscription.event_type),
         true <- function_exported?(producer, :example, 1),
         %{} = data <- producer.example(subscription.version) do
      data
    else
      _ -> nil
    end
  end

  defp event_key(subscription, data) do
    with producer when not is_nil(producer) <- Registry.producer_for(subscription.event_type),
         true <- function_exported?(producer, :event_key, 2),
         key when not is_nil(key) <- producer.event_key(subscription.version, data) do
      key
    else
      _ -> "test-event-key"
    end
  rescue
    _ -> "test-event-key"
  end
end
