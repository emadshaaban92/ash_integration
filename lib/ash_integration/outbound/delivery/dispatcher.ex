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
  sweep). The lease (`Supervisor.lease_seconds/0`, default-derived from `max_demand ×
  http_max_timeout_ms` so it outlives a row's wait in the in-flight buffer, or a host
  override) bounds duplicate concurrent sends. See `design/delivery-retry-model.md`.
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

  ## Per-connection in-flight cap (`max_in_flight_per_connection`)

  `max_in_flight` (`K`, from the stage config, threaded here via the producer) is a
  **fairness cap**: a connection already holding `≥ K` live-lease rows is skipped this
  round, so one connection with a slow-but-not-failing endpoint cannot lease every
  batch processor and starve the others (see the `Supervisor` moduledoc for *why*
  `partition_by` alone doesn't prevent this). `nil` (the default arity-1 call) means
  uncapped — the original single-`UPDATE` claim.

  Three properties the capped SQL holds, all in **one atomic statement**:

    * **No over-admission past `K`, even under concurrent claimers.** A single command
      is one snapshot: the per-connection live-lease count (`leased`) and the claimable
      candidates are read at the same instant. Each connection's candidates are ranked
      by `event_id` (`row_number()`), and only the lowest `K − leased` are eligible —
      so every claimer independently targets the *same* deterministic prefix of a
      connection's rows. `FOR UPDATE SKIP LOCKED` (skipping rows a concurrent claimer
      holds) plus the re-checked freshness qual at the locking step (EvalPlanQual drops
      rows a concurrent claimer already committed) then split that bounded prefix
      between claimers rather than doubling it. The only way real in-flight briefly
      exceeds `K` is a lease *expiry* re-claim of an abandoned row — the standard
      at-least-once window, not a count race.
    * **Fairness — a capped connection never shadows younger connections.** The cap
      filter is applied **before** the global `ORDER BY event_id … LIMIT`, so a slow
      connection's older-but-over-cap rows are removed from the candidate set entirely
      and never consume the round's `limit` budget. Its first `K` rows still sort
      ahead by `event_id`; only its surplus waits.
    * **A live lease is a `:scheduled` row with a fresh `claimed_at`.** `leased` counts
      exactly the rows occupying a processor (claimed, mid-send, or crashed-within-
      lease); an expired-lease row is a candidate again and not counted, so the cap and
      the lease share one boundary.
  """
  def claim(limit, max_in_flight \\ nil)

  def claim(limit, max_in_flight)
      when is_integer(limit) and limit > 0 and
             (is_nil(max_in_flight) or (is_integer(max_in_flight) and max_in_flight > 0)) do
    repo = AshIntegration.repo()
    resource = AshIntegration.event_delivery_resource()
    table = AshPostgres.DataLayer.Info.table(resource)
    lease = Stage.lease_seconds()

    {sql, params} = claim_sql(table, lease, limit, max_in_flight)

    # UPDATE (lease + bump) and reload share ONE transaction, opened directly on the repo
    # so we can pass `log:` — the begin/commit envelope then honours `query_log_level` just
    # like the claim UPDATE (`Ash.transact` can't forward `:log`, so with it the bare
    # begin/commit leaked at `:debug` even when the claim query was silenced). Ecto's
    # `Repo.transaction` does NOT roll back on an `{:error, _}` return, only on a raise or an
    # explicit `rollback/1`, so on a UPDATE/reload blip we call `repo.rollback(reason)`
    # ourselves — that keeps the "never leased-but-unemitted" guarantee: the lease + attempt
    # bump roll back with the reload, leaving a `:scheduled` row claimable. Any failure
    # yields [].
    repo.transaction(
      fn ->
        case claim_and_load(repo, sql, params) do
          {:error, reason} -> repo.rollback(reason)
          deliveries -> deliveries
        end
      end,
      log: AshIntegration.query_log_level()
    )
    |> case do
      {:ok, deliveries} ->
        deliveries

      {:error, error} ->
        Logger.error("Outbound delivery: claim failed: #{inspect(error)}")
        []
    end
  rescue
    # `Repo.transaction` re-raises if the function raises (e.g. a pool-checkout timeout on
    # the UPDATE itself); the transaction has already rolled back. A claim must never
    # crash the producer — hold the demand and let the next poll retry.
    e ->
      Logger.error("Outbound delivery: claim failed: #{Exception.message(e)}")
      []
  end

  # ── Claim SQL (uncapped vs per-connection-capped) ───────────────────────────

  # Uncapped: the original single-`UPDATE` claim. `$1` = lease seconds, `$2` = limit.
  defp claim_sql(table, lease, limit, nil) do
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

    {sql, [lease, limit]}
  end

  # Capped at `K` (`$3`) live-lease rows per connection, in ONE statement so the
  # count-and-lease can't race two claimers past `K` (see `claim/2`'s moduledoc for the
  # full argument). `$1` = lease seconds, `$2` = limit, `$3` = K.
  #
  #   * `leased`     — per-connection count of rows CURRENTLY occupying a processor:
  #                    `:scheduled` with a fresh (unexpired) `claimed_at`. The same
  #                    single-statement snapshot that reads this reads the candidates,
  #                    so the two are consistent.
  #   * `candidates` — the claimable rows (`:scheduled`, lease free), each ranked within
  #                    its connection by `event_id` via `row_number()`. (A window
  #                    function can't sit in a `FOR UPDATE` scan, so the ranking and the
  #                    lock are separate query levels.)
  #   * `eligible`   — keep only a connection's lowest `K − leased` claimable rows
  #                    (`rn <= K − leased`), THEN apply the global `event_id` order +
  #                    `LIMIT`. Filtering before the `LIMIT` is what stops an over-cap
  #                    connection's older rows from shadowing younger connections.
  #
  # The final `UPDATE` re-scans the base table for those eligible ids with `FOR UPDATE
  # SKIP LOCKED` and re-applies the lease-free qual, so a row a concurrent claimer holds
  # is skipped and a row it already committed is dropped by EvalPlanQual — the eligible
  # prefix is split between claimers, never doubled.
  defp claim_sql(table, lease, limit, max_in_flight) when is_integer(max_in_flight) do
    sql = """
    WITH leased AS (
      SELECT connection_id, count(*) AS n
      FROM #{table}
      WHERE state = 'scheduled'
        AND claimed_at IS NOT NULL
        AND claimed_at >= now() - make_interval(secs => $1)
      GROUP BY connection_id
    ),
    candidates AS (
      SELECT d.id,
             d.event_id,
             row_number() OVER (PARTITION BY d.connection_id ORDER BY d.event_id ASC) AS rn,
             d.connection_id
      FROM #{table} d
      WHERE d.state = 'scheduled'
        AND (d.claimed_at IS NULL OR d.claimed_at < now() - make_interval(secs => $1))
    ),
    eligible AS (
      SELECT c.id, c.event_id
      FROM candidates c
      LEFT JOIN leased l ON l.connection_id = c.connection_id
      WHERE c.rn <= ($3 - COALESCE(l.n, 0))
      ORDER BY c.event_id ASC
      LIMIT $2
    )
    UPDATE #{table} AS d
    SET claimed_at = now(), attempts = d.attempts + 1
    FROM (
      SELECT t.id
      FROM #{table} t
      WHERE t.id IN (SELECT id FROM eligible)
        AND t.state = 'scheduled'
        AND (t.claimed_at IS NULL OR t.claimed_at < now() - make_interval(secs => $1))
      FOR UPDATE SKIP LOCKED
    ) AS claimable
    WHERE d.id = claimable.id
    RETURNING d.id::text
    """

    {sql, [lease, limit, max_in_flight]}
  end

  # Runs inside the claim transaction: lease UPDATE, then reload by id. Returns the bare
  # loaded deliveries (so the transaction commits and yields `{:ok, _}`) or `{:error, reason}`
  # on a UPDATE/reload failure (the caller then `rollback/1`s to undo the lease).
  defp claim_and_load(repo, sql, params) do
    with {:ok, %{rows: rows}} <-
           repo.query(sql, params, log: AshIntegration.query_log_level()),
         {:ok, deliveries} <- rows |> Enum.map(fn [id] -> id end) |> load_claimed() do
      deliveries
    end
  end

  defp load_claimed([]), do: {:ok, []}

  defp load_claimed(ids) do
    # Load only the source Event's `created_at` (not its payload) so the relay can
    # report the source-change → ack latency on a successful delivery.
    event_query = Ash.Query.select(AshIntegration.event_resource(), [:created_at])

    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load([:connection, :subscription, event: event_query])
    |> Ash.read(authorize?: false)
    |> case do
      # Preserve the claim's FIFO (event occurrence) order — the read does not
      # guarantee it.
      {:ok, deliveries} -> {:ok, Enum.sort_by(deliveries, & &1.event_id)}
      {:error, error} -> {:error, error}
    end
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
