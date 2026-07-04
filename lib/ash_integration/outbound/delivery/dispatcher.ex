defmodule AshIntegration.Outbound.Delivery.Dispatcher do
  @moduledoc """
  Claim + bookkeeping for the **delivery relay** — the delivery-side mirror of
  `AshIntegration.Outbound.Dispatch.Dispatcher`.

  The `EventScheduler` promotes `pending`/`:failed → :scheduled` (owning ordering:
  lane-head selection, the high-water gate, suspension, backoff eligibility). This
  module's `claim/1` then leases those already-due `:scheduled` rows for the relay's
  producer to execute. It also holds `backoff_until/1` — the durable exponential
  backoff cursor (Oban's one irreplaceable feature, made a column:
  `EventDelivery.next_attempt_at`), which the relay stamps on a retryable failure and
  the scheduler honors at promotion.

  ## Attempts bump on CLAIM (an honest count, not a ceiling)

  `claim/1` bumps `attempts` and stamps the soft `claimed_at` lease **atomically**.
  Bumping on the claim — not only on a graceful failure — keeps the count honest even
  when the relay CRASHES mid-send: the increment already happened, so a stale claim
  can't be double-counted. There is **no attempt ceiling**: `attempts` never gates
  claiming and is never forced or reset (terminal-ness lives in `terminal_reason`).
  A retryable failure retries forever, paced by `next_attempt_at` backoff and bounded
  operationally by suspension + probe (and, if configured, the age-based `:expired`
  sweep). The derived lease (`Supervisor.lease_seconds/0`, sized ≫ the transport
  timeout) bounds duplicate concurrent sends. See `design/delivery-retry-model.md`.
  """

  require Ash.Query
  require Logger

  alias AshIntegration.Outbound.Delivery.Supervisor, as: Stage

  # ── Claim (lease over due `:scheduled` rows) ────────────────────────────────

  @doc """
  Atomically claim up to `limit` DUE `:scheduled` `EventDelivery` rows for delivery
  and return them as loaded structs (connection + subscription loaded), oldest
  (`event_id`, the parent Event's occurrence-ordered UUIDv7) first.

  A row is claimable when it is `:scheduled` and its lease is free (`claimed_at` null
  or older than the lease window). It needs no backoff or ceiling check here: the
  scheduler only promotes a row to `:scheduled` once it is actually due (past its
  `next_attempt_at`, non-terminal), so a `:scheduled` row is by construction ready to
  run. `FOR UPDATE SKIP LOCKED` lets multiple passes/nodes claim disjoint rows in
  parallel; the partial unique index `(connection_id, event_key) WHERE state IN
  ('scheduled','failed')` is the one-active-head-per-lane backstop. The single UPDATE
  stamps `claimed_at` and bumps `attempts`, so two claimers can never grab the same
  row.
  """
  def claim(limit) when is_integer(limit) and limit > 0 do
    repo = AshIntegration.repo()
    table = AshPostgres.DataLayer.Info.table(AshIntegration.event_delivery_resource())
    lease = Stage.lease_seconds()

    sql = """
    UPDATE #{table} AS d
    SET claimed_at = now(), attempts = d.attempts + 1
    FROM (
      SELECT id FROM #{table}
      WHERE state = 'scheduled'
        AND (claimed_at IS NULL OR claimed_at < now() - make_interval(secs => $1))
      ORDER BY event_id ASC
      LIMIT $2
      FOR UPDATE SKIP LOCKED
    ) AS claimable
    WHERE d.id = claimable.id
    RETURNING d.id::text
    """

    case repo.query(sql, [lease, limit], log: AshIntegration.query_log_level()) do
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
    # Load only the source Event's `created_at` (not its payload) so the relay can
    # report the source-change → ack latency on a successful delivery.
    event_query = Ash.Query.select(AshIntegration.event_resource(), [:created_at])

    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load([:connection, :subscription, event: event_query])
    |> Ash.read!(authorize?: false)
    # Preserve the claim's FIFO (event occurrence) order — the read does not
    # guarantee it.
    |> Enum.sort_by(& &1.event_id)
  end

  # ── Durable backoff (next_attempt_at) ───────────────────────────────────────

  @doc """
  The `next_attempt_at` to stamp on a retryable failure: `now + delay`, where
  `delay = min(base * 2^(attempts-1), cap)` with ±jitter. `attempts` is the
  post-claim value, so the first failure (attempts = 1) waits ~`base`. Honored by the
  scheduler's promotion gate (`next_attempt_at IS NULL OR next_attempt_at <= now()`),
  so the `:failed` head holds its lane but is idle until the backoff elapses.

  When the server stated its own pacing (`retry_after_ms`, parsed from a retryable
  response's `Retry-After` header by the transport), that wins over the exponential
  delay — exact (no jitter: it is the target's explicit ask), but **clamped** to
  `backoff_max_ms` so a hostile or buggy header can't park a lane indefinitely.
  """
  def backoff_until(attempts, retry_after_ms \\ nil)

  def backoff_until(_attempts, retry_after_ms)
      when is_integer(retry_after_ms) and retry_after_ms >= 0 do
    delay = min(retry_after_ms, Stage.backoff_max_ms())
    DateTime.add(DateTime.utc_now(), delay, :millisecond)
  end

  def backoff_until(attempts, _retry_after_ms) when is_integer(attempts) and attempts >= 1 do
    base = Stage.backoff_base_ms()
    cap = Stage.backoff_max_ms()

    # 2^(attempts-1), capped before the multiply can overflow into a huge int.
    factor = :math.pow(2, min(attempts - 1, 32))
    delay = min(round(base * factor), cap)

    jitter_span = round(delay * Stage.backoff_jitter_ratio())
    jitter = if jitter_span > 0, do: :rand.uniform(2 * jitter_span + 1) - 1 - jitter_span, else: 0

    DateTime.add(DateTime.utc_now(), max(delay + jitter, 0), :millisecond)
  end
end
