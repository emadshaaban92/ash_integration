defmodule AshIntegration.Outbound.PoolCheck do
  @moduledoc """
  Boot-time sanity check: does the outbound runtime's total concurrency fit inside
  the host repo's DB connection pool?

  The dispatch and delivery stages each fan work out across many processes that all
  hold a repo connection while they run, and every one of them draws from the SAME
  pool — the host's `config :ash_integration, repo: …` (Ecto's default `pool_size`
  is **10**):

    * **dispatch** — `dispatch: [concurrency: …]` (default `System.schedulers_online()`)
      Broadway batchers, each running the fan-out transaction (stamp `dispatched_at`
      + delivery inserts + coalesce) — one checked-out connection apiece. The
      dispatch processors additionally read subscriptions from the pool, so the true
      peak is higher than the figure below.
    * **delivery** — `delivery: [concurrency: …]` (default **25**) Broadway
      processors, each running the per-row bookkeeping write (`:deliver` /
      `:record_failure`) — one connection apiece.
    * the always-on singletons — both relay producers' claim `UPDATE … RETURNING`,
      the scheduler sweep, the health recompute/probe, and the retention sweep —
      one connection each while active (5 total, see `@singleton_demand`).

  Nothing else lines these knobs up against the pool. A host that leaves `pool_size`
  at the default while accepting the default concurrency (already
  `schedulers_online() + 25 + overhead` — tens of connections) silently
  oversubscribes it, and the failure mode is both nasty and hard to trace: under
  load the excess checkouts wait on `DBConnection`'s queue and time out, and those
  timeouts surface on the dispatch/delivery **failure** paths — where a dispatch
  claim/transaction timeout is turned into `Broadway.Message.failed/2` and burns a
  `dispatch_attempts` toward the poison ceiling (`Dispatch.Supervisor.max_attempts/0`)
  for a row that was never actually poison.

  So this runs once at boot (from `AshIntegration.Supervisor`) and emits a loud,
  actionable `Logger.warning` when the concurrency total exceeds the pool.

  ## Why it warns rather than raises

  The shipped defaults *already* exceed a default pool (`schedulers_online() + 25 +
  5` ≫ 10), so a hard `raise` would refuse every out-of-the-box boot. The estimate
  is also a conservative **floor** — the dispatch processors' subscription reads are
  not counted — so if even this lower bound exceeds the pool the host is definitely
  under-provisioned, but a value *at or below* it is not a guarantee of safety. A
  warning is the honest signal for a tuning relationship whose exact peak depends on
  load; the host raises `pool_size` (or lowers the concurrency knobs) to clear it.
  """
  require Logger

  alias AshIntegration.Outbound.Delivery.Supervisor, as: Delivery
  alias AshIntegration.Outbound.Dispatch.Supervisor, as: Dispatch

  # DBConnection's own default when a host leaves `pool_size` unset — so the check
  # uses the same number the pool actually will.
  @default_pool_size 10

  # Always-on background processes that each hold at most one repo connection while
  # active: the dispatch + delivery relay producers (claim query), the scheduler
  # sweep, the health recompute/probe, and the retention sweep. A steady-state
  # approximation — on-demand work (reprocess) and the one-shot boot checks are not
  # counted.
  @singleton_demand 5

  @doc """
  Compare the outbound concurrency total against the host repo's pool and warn if it
  doesn't fit. Always returns `:ok` and never raises (see the moduledoc for why it
  warns rather than fails the boot). If no repo is resolvable yet, the check is
  skipped — there is nothing to compare against.
  """
  def warn_if_oversubscribed do
    case pool_size() do
      {:ok, pool} ->
        demand = concurrency_demand()
        if oversubscribed?(demand, pool), do: warn(demand, pool)
        :ok

      :error ->
        :ok
    end
  end

  @doc """
  Peak repo connections the outbound runtime can check out concurrently, as a
  conservative floor: `dispatch.concurrency + delivery.concurrency + singletons`.
  See the moduledoc for what each term covers.
  """
  def concurrency_demand do
    Dispatch.concurrency() + Delivery.concurrency() + @singleton_demand
  end

  @doc false
  def oversubscribed?(demand, pool) when is_integer(demand) and is_integer(pool),
    do: demand > pool

  @doc """
  The host repo's configured `pool_size`, falling back to DBConnection's default of
  #{@default_pool_size} when unset. `{:ok, size}`, or `:error` when no repo is
  configured (nothing to check).
  """
  def pool_size do
    {:ok, Keyword.get(AshIntegration.repo().config(), :pool_size, @default_pool_size)}
  rescue
    _ -> :error
  end

  defp warn(demand, pool) do
    Logger.warning("""
    AshIntegration: the outbound runtime's concurrency (#{demand}) exceeds the repo \
    connection pool (#{pool}).

    Dispatch batchers (dispatch: [concurrency: #{Dispatch.concurrency()}]), delivery \
    writers (delivery: [concurrency: #{Delivery.concurrency()}]), the relay producers, \
    the scheduler, the health sweep, and the retention sweep all draw from the host \
    repo's pool. When they exceed it, the excess checkouts queue on DBConnection and \
    time out under load — and those timeouts land on the dispatch/delivery failure \
    paths, so a queue timeout can burn a dispatch_attempts toward the poison ceiling \
    for a row that was never poison.

    Raise the repo's `pool_size` to at least #{demand}, or lower the `:concurrency` \
    knobs under `config :ash_integration, dispatch:/delivery:`. This is a conservative \
    floor (dispatch subscription reads are not counted), so size with headroom.\
    """)
  end
end
