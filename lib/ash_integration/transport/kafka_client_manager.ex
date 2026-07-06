defmodule AshIntegration.Transport.KafkaClientManager do
  @moduledoc """
  Manages brod client lifecycle for Kafka integrations.

  One brod client is maintained per outbound integration, keyed by integration ID.
  Clients are started on first delivery and torn down after an idle timeout.

  ## Correctness guarantees

  `ensure_client/4` is a synchronous `GenServer.call` that, before returning `:ok`,
  guarantees a brod client running the *current* effective config is alive for the
  integration:

    * **Config changes apply.** The effective config (brokers + the kpro
      client_config carrying TLS/SASL + the producer config) is fingerprinted and
      stored per integration. When it changes — rotated SASL credentials, new
      brokers, different acks — the old client is stopped and a new one started
      with the new config, so a fingerprint change can't be masked by a
      still-alive client (and brod_sup can't keep restarting a crashed client with
      stale config).

    * **Every topic gets a producer.** The client is started with brod's
      `auto_start_producers: true` and the delivery's producer config as
      `default_producer_config`, so a produce to *any* topic (a second
      subscription on the same connection, a topic seen for the first time)
      lazily spawns its producer instead of failing with `:producer_not_found`.
      There is no separate per-topic `start_producer` step to leave half-started.

    * **No orphaned clients.** `start_client` is the only fallible brod call: if it
      fails, nothing is running and nothing is tracked. A client that is alive but
      *untracked* — a brod client that survived a manager crash/restart (manager
      state resets to empty while brod_sup keeps the client) — is adopted by
      stopping and restarting it under the current config on the next
      `ensure_client/4`.

  Because activity is recorded synchronously inside the `ensure_client/4` call
  (not via an async cast), a `:cleanup` message processed afterwards sees a fresh
  timestamp and cannot tear the client down between `ensure_client/4` returning
  `:ok` and the caller's produce.

  ## Operational characteristics (costs of the above)

    * **Config edits are applied live.** A config change stops the running client
      and starts a new one *immediately*, so an operator rotating SASL credentials
      (or editing brokers) at 5pm applies the change to in-flight traffic at once,
      not at the next client restart. The flip side: an edit to *unreachable*
      brokers or *bad* credentials takes a previously-healthy pipeline down — the
      old client is stopped first, and if the new `start_client` fails, deliveries
      fail (retryably) until the config is fixed or reverted. This inverts the old
      behaviour, where a bad edit was silently ignored while the old client stayed
      alive. It is deliberate: config should mean what it says, and the suspension
      subsystem surfaces a persistently-bad edit.

    * **A manager restart briefly restarts healthy clients.** After the manager
      process crashes/restarts, its state is empty but brod clients survive under
      `brod_sup`; the first delivery per integration adopts each survivor by
      stopping and restarting it (its config is unknown, so a restart is the only
      way to guarantee current config). Under load this shows up as a short burst
      of produce failures across all active integrations at once — expected, not a
      mystery incident.

    * **Produce serializes through this one process.** Every delivery calls
      `ensure_client/4`, so all Kafka produce for all integrations funnels through
      this single GenServer (the price of recording activity synchronously — see
      the race note above). A restart that *stalls* — e.g. `stop_client` on a
      wedged brod client — head-of-line-blocks deliveries for *other*,
      healthy integrations until their `GenServer.call` times out. Mitigating
      factor: `:brod.start_client/3` does NOT block on unreachable brokers in
      brod 4.x — `brod_client:init/1` only creates an ETS table and returns
      `{ok, state, {continue, init}}`, with the metadata/broker connection made
      asynchronously in `handle_continue/2` *after* `start_client` has returned —
      so the common misconfigured-broker case is fast. If head-of-line blocking
      ever becomes a real problem, the fix is per-integration processes
      (`Registry` + `DynamicSupervisor`), a larger change deferred out of this
      module for now.
  """

  use GenServer

  require Logger

  alias AshIntegration.Transport.KafkaClientManager.BrodBackend
  alias AshIntegration.Transport.Utils

  # The `:brod` interaction boundary. A map of funs (not a bare module) so tests
  # can inject a fake that closes over its own liveness/failure state.
  @default_backend %{
    start_client: &BrodBackend.start_client/3,
    stop_client: &BrodBackend.stop_client/1,
    alive?: &BrodBackend.alive?/1
  }

  # Public API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Ensures a brod client running the current effective config is alive for the
  given integration, starting or restarting it as needed. Returns `:ok` or
  `{:error, reason}`.

  `brokers` is the parsed `[{host_charlist, port}]` list, `client_config` the kpro
  client options (TLS/SASL), and `producer_config` the brod producer options —
  applied to every topic via `auto_start_producers`. A change to any of these
  restarts the client so the new config takes effect.
  """
  @spec ensure_client(
          String.t(),
          [{charlist(), non_neg_integer()}],
          keyword(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def ensure_client(integration_id, brokers, client_config, producer_config \\ []) do
    GenServer.call(
      __MODULE__,
      {:ensure, integration_id, brokers, client_config, producer_config}
    )
  end

  @doc """
  Records activity for a client to prevent idle teardown.
  """
  @spec touch(String.t()) :: :ok
  def touch(integration_id) do
    GenServer.cast(__MODULE__, {:touch, integration_id})
  end

  @doc """
  Returns the brod client ID atom for a given integration ID.
  """
  # sobelow_skip ["DOS.BinToAtom"]
  # `:brod` registers its client under a named (atom) process, so an atom is
  # required here. `integration_id` is a Connection's DB-generated UUID — a
  # bounded, operator-controlled set, never arbitrary user input — so this can't
  # be driven to exhaust the atom table.
  @spec client_id_for(String.t()) :: atom()
  def client_id_for(integration_id) do
    :"ash_kafka_#{integration_id}"
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    if Utils.available?(:kafka) do
      state = %{
        clients: %{},
        backend: Keyword.get(opts, :backend, @default_backend),
        # `nil` → read the idle timeout live from app env on each cleanup tick (so
        # a release's runtime config is honoured). Tests pin a fixed value here to
        # exercise teardown without mutating global app env under async.
        idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms)
      }

      schedule_cleanup(state)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_call(
        {:ensure, integration_id, brokers, client_config, producer_config},
        _from,
        state
      ) do
    client_id = client_id_for(integration_id)
    config = brod_client_config(client_config, producer_config)
    fingerprint = fingerprint(brokers, config)
    tracked = Map.get(state.clients, integration_id)
    alive? = state.backend.alive?.(client_id)

    if match?(%{fingerprint: ^fingerprint}, tracked) and alive? do
      # Up to date and running: refresh activity (also keeps `:cleanup` from
      # tearing it down out from under the imminent produce) and reuse it.
      {:reply, :ok, track(state, integration_id, fingerprint)}
    else
      restart(state, integration_id, client_id, brokers, config, fingerprint, tracked, alive?)
    end
  end

  # (Re)start the client so it reflects the current config. Covers a config
  # change (stale fingerprint), a dead tracked client, and an alive-but-untracked
  # orphan left by a manager restart — all of which must first tear down whatever
  # is there (idempotent, safe when nothing is) before starting fresh.
  defp restart(state, integration_id, client_id, brokers, config, fingerprint, tracked, alive?) do
    if alive? or tracked, do: state.backend.stop_client.(client_id)

    case state.backend.start_client.(brokers, client_id, config) do
      :ok ->
        Logger.info("Started Kafka client for integration #{integration_id}")
        {:reply, :ok, track(state, integration_id, fingerprint)}

      {:error, reason} ->
        # Nothing is running and nothing is tracked — no orphan to leak, and the
        # next delivery will retry the start.
        {:reply, {:error, reason}, forget(state, integration_id)}
    end
  end

  @impl true
  def handle_cast({:touch, integration_id}, state) do
    case Map.get(state.clients, integration_id) do
      %{fingerprint: fingerprint} -> {:noreply, track(state, integration_id, fingerprint)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = now() - idle_timeout_ms(state)

    {expired, active} =
      Enum.split_with(state.clients, fn {_id, %{last_active: last_active}} ->
        last_active < cutoff
      end)

    for {integration_id, _} <- expired do
      client_id = client_id_for(integration_id)

      Logger.info("Stopping idle Kafka client for integration #{integration_id}")
      state.backend.stop_client.(client_id)
    end

    schedule_cleanup(state)
    {:noreply, %{state | clients: Map.new(active)}}
  end

  # The brod client config the manager actually starts a client with: the kpro
  # options (TLS/SASL) plus `auto_start_producers` so a produce to any topic
  # lazily spawns its producer using `default_producer_config`. This removes the
  # separate, fallible `start_producer` step and covers additional topics on the
  # same connection.
  defp brod_client_config(client_config, producer_config) do
    client_config ++
      [auto_start_producers: true, default_producer_config: producer_config]
  end

  # A collision-free fingerprint of everything that determines client identity, so
  # a changed broker, rotated SASL credential, or changed producer config yields a
  # different fingerprint and triggers a restart.
  #
  # A SHA-256 digest of the config term — deliberately NOT `phash2` (27-bit, so two
  # configs could in principle collide, and a fingerprint collision on a rotated
  # credential is precisely the bug this guards against), and NOT the raw
  # `{brokers, config}` term compared with `==` (the `client_config` carries the
  # DECRYPTED SASL password, which must not sit in this GenServer's state where a
  # crash-log state dump would leak it). The digest is collision-free in practice
  # and secret-free. `term_to_binary` is deterministic for equal terms, including
  # the ssl `match_fun` closure — the "same config twice ⇒ no restart" test is the
  # guard that keeps a future TLS-opts refactor (a per-call closure) from silently
  # restarting the client on every delivery.
  defp fingerprint(brokers, config) do
    :crypto.hash(:sha256, :erlang.term_to_binary({brokers, config}))
  end

  defp track(state, integration_id, fingerprint) do
    put_in(state, [:clients, integration_id], %{fingerprint: fingerprint, last_active: now()})
  end

  defp forget(state, integration_id) do
    %{state | clients: Map.delete(state.clients, integration_id)}
  end

  defp schedule_cleanup(state) do
    Process.send_after(self(), :cleanup, check_interval_ms(state))
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Idle-teardown timing. A `nil` override reads it at RUNTIME (`Application.get_env`)
  # so a release's `runtime.exs` config is honoured rather than baked in at compile
  # time; the lookup runs only on the infrequent cleanup tick, so its cost is
  # negligible.
  defp idle_timeout_ms(%{idle_timeout_ms: ms}) when is_integer(ms), do: ms

  defp idle_timeout_ms(_state),
    do: Application.get_env(:ash_integration, :kafka_idle_timeout_ms, 300_000)

  defp check_interval_ms(state), do: max(div(idle_timeout_ms(state), 2), 1)
end
