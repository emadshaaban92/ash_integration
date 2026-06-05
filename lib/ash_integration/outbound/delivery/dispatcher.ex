defmodule AshIntegration.Outbound.Delivery.Dispatcher do
  @moduledoc """
  Claim + bookkeeping for the **delivery relay** — the delivery-side mirror of
  `AshIntegration.Outbound.Dispatch.Dispatcher`.

  The `EventScheduler` promotes `pending → scheduled` (owning ordering: lane-head
  selection, the high-water gate #57, suspension). This module's `claim/1` then
  leases those `:scheduled` rows for the relay's producer to execute. It also holds
  the two delivery-only mechanisms the relay's failure path needs:

    * `backoff_until/1` — the durable exponential backoff cursor (Oban's one
      irreplaceable feature, made a column: `EventDelivery.next_attempt_at`); and
    * `poison?/1` + `record_poison/2` — the terminal-policy surfacing (#60/#74).

  ## Attempts bump on CLAIM (correctness, not tuning)

  `claim/1` bumps `attempts` and stamps the soft `claimed_at` lease **atomically**.
  Bumping on the claim — not only on a graceful `:record_attempt_error` — is what
  makes a relay that CRASHES mid-send safe: the increment already happened, so the
  lease expires, another pass re-claims, and the ceiling eventually leaves it stuck
  instead of crash-looping forever (the #74 failure mode). The consequence is
  deliberate: `max_attempts` counts CLAIMS, so a slow-but-fine target whose lease
  expires mid-send can be falsely poisoned (stuck `:scheduled`, lane blocked). The
  derived lease (`Supervisor.lease_seconds/0`, sized ≫ the transport timeout) is
  what bounds both that false poisoning and duplicate concurrent sends.
  """

  require Ash.Query
  require Logger

  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage

  # ── Claim (lease over due `:scheduled` rows) ────────────────────────────────

  @doc """
  Atomically claim up to `limit` DUE `:scheduled` `EventDelivery` rows for delivery
  and return them as loaded structs (connection + subscription loaded), oldest
  (`event_id`, the parent Event's occurrence-ordered UUIDv7) first.

  A row is claimable when it is `:scheduled`, under the attempt ceiling, its backoff
  has elapsed (`next_attempt_at` null/past), and its lease is free (`claimed_at`
  null or older than the lease window). `FOR UPDATE SKIP LOCKED` lets multiple
  passes/nodes claim disjoint rows in parallel; the partial unique index
  `(connection_id, event_key) WHERE state = 'scheduled'` is the one-in-flight
  backstop. The single UPDATE stamps `claimed_at` and bumps `attempts`, so two
  claimers can never grab the same row.

  Rows at/over `max_attempts` are **never claimed** — terminal (poison), left
  `:scheduled` with their lane blocked until a human/host intervenes (#60).
  """
  def claim(limit) when is_integer(limit) and limit > 0 do
    repo = AshIntegration.repo()
    table = AshPostgres.DataLayer.Info.table(AshIntegration.event_delivery_resource())
    lease = Stage.lease_seconds()
    max_attempts = Stage.max_attempts()

    sql = """
    UPDATE #{table} AS d
    SET claimed_at = now(), attempts = d.attempts + 1
    FROM (
      SELECT id FROM #{table}
      WHERE state = 'scheduled'
        AND attempts < $2
        AND (next_attempt_at IS NULL OR next_attempt_at <= now())
        AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $1))
      ORDER BY event_id ASC
      LIMIT $3
      FOR UPDATE SKIP LOCKED
    ) AS claimable
    WHERE d.id = claimable.id
    RETURNING d.id::text
    """

    case repo.query(sql, [lease, max_attempts, limit], log: AshIntegration.query_log_level()) do
      {:ok, %{rows: rows}} ->
        ids = Enum.map(rows, fn [id] -> id end)
        load_claimed(ids)

      {:error, error} ->
        Logger.error("Outbound delivery: claim query failed: #{inspect(error)}")
        []
    end
  end

  defp load_claimed([]), do: []

  defp load_claimed(ids) do
    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load([:connection, :subscription])
    |> Ash.read!(authorize?: false)
    # Preserve the claim's FIFO (event occurrence) order — the read does not
    # guarantee it.
    |> Enum.sort_by(& &1.event_id)
  end

  # ── Durable backoff (next_attempt_at) ───────────────────────────────────────

  @doc """
  The `next_attempt_at` to stamp on a retryable failure: `now + delay`, where
  `delay = min(base * 2^(attempts-1), cap)` with ±jitter. `attempts` is the
  post-claim value, so the first failure (attempts = 1) waits ~`base`. Honored by
  `claim/1`'s `next_attempt_at <= now()` gate, so the lane stays blocked but idle
  until the backoff elapses.
  """
  def backoff_until(attempts) when is_integer(attempts) and attempts >= 1 do
    base = Stage.backoff_base_ms()
    cap = Stage.backoff_max_ms()

    # 2^(attempts-1), capped before the multiply can overflow into a huge int.
    factor = :math.pow(2, min(attempts - 1, 32))
    delay = min(round(base * factor), cap)

    jitter_span = round(delay * Stage.backoff_jitter_ratio())
    jitter = if jitter_span > 0, do: :rand.uniform(2 * jitter_span + 1) - 1 - jitter_span, else: 0

    DateTime.add(DateTime.utc_now(), max(delay + jitter, 0), :millisecond)
  end

  # ── Terminal (poison) policy (#60/#74) ──────────────────────────────────────

  @doc """
  Whether this delivery has reached the terminal (poison) ceiling — `attempts` (the
  post-claim value) is at/over `max_attempts`. A poison row is left `:scheduled`,
  keeps its one-in-flight slot, and its lane stays blocked; `claim/1` never picks it
  up again. Never auto-resolved.
  """
  def poison?(%{attempts: attempts}), do: attempts >= Stage.max_attempts()

  @doc """
  Surface a terminal (poison) delivery loudly — operator log + `[:ash_integration,
  :delivery, :poison]` telemetry — exactly once (the attempt that crossed the
  ceiling). Mirrors the dispatch side; the row is deliberately left `:scheduled`
  (lane blocked) by the relay, never auto-resolved.
  """
  def record_poison(delivery, reason) do
    Logger.error(
      "Outbound delivery: poison delivery #{delivery.id} (#{delivery.event_type}, key " <>
        "#{delivery.event_key}) stuck after #{delivery.attempts} delivery attempts — left " <>
        "scheduled, lane blocked (no auto-resolve); last error: #{reason}"
    )

    :telemetry.execute(
      [:ash_integration, :delivery, :poison],
      %{attempts: delivery.attempts},
      %{
        event_delivery_id: delivery.id,
        event_type: delivery.event_type,
        event_key: delivery.event_key,
        connection_id: delivery.connection_id,
        subscription_id: delivery.subscription_id
      }
    )

    :ok
  end

  @doc """
  The poison-flavoured `last_error` recorded on the attempt that crosses the ceiling.
  """
  def poison_message(attempts, reason) do
    "poison: stuck after #{attempts} delivery attempts (no auto-resolve; left " <>
      "scheduled, lane blocked); last error: #{reason}"
  end
end
