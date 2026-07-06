defmodule AshIntegration.Transport.KafkaClientManagerTest do
  # Exercises the client lifecycle state machine WITHOUT a real broker: the
  # `:brod` interaction boundary is injected as a fake backend that records
  # start/stop calls and simulates client liveness and start failures. Each test
  # runs its own manager instance (unnamed pid) with its own idle timeout, so the
  # suite stays `async: true` and never mutates global app env.
  use ExUnit.Case, async: true

  # The manager logs client start/stop at :info; silence it so the suite output
  # stays readable.
  @moduletag capture_log: true

  alias AshIntegration.Outbound.Wire.Transports.Kafka
  alias AshIntegration.Transport.KafkaClientManager, as: Manager

  @brokers [{~c"broker-1", 9092}]
  @client_config [ssl: [verify: :verify_peer]]
  @producer_config [required_acks: -1, max_linger_ms: 0]

  # --- Fake backend -------------------------------------------------------

  # A `%{start_client:, stop_client:, alive?:}` backend closing over a per-test
  # Agent. `start_client` marks the client alive and returns `:ok` unless the test
  # armed a failure for it; `stop_client` records and forgets it; `alive?` reads
  # the simulated liveness set. This is the same shape the manager's production
  # `BrodBackend` module provides.
  defp new_backend do
    {:ok, agent} =
      Agent.start_link(fn -> %{alive: MapSet.new(), starts: [], stops: [], fail: %{}} end)

    backend = %{
      start_client: fn brokers, client_id, config ->
        Agent.get_and_update(agent, fn state ->
          state =
            update_in(
              state.starts,
              &(&1 ++ [%{brokers: brokers, client_id: client_id, config: config}])
            )

          case Map.get(state.fail, client_id) do
            nil -> {:ok, put_in(state.alive, MapSet.put(state.alive, client_id))}
            reason -> {{:error, reason}, state}
          end
        end)
      end,
      stop_client: fn client_id ->
        Agent.update(agent, fn state ->
          state = update_in(state.stops, &(&1 ++ [client_id]))
          put_in(state.alive, MapSet.delete(state.alive, client_id))
        end)

        :ok
      end,
      alive?: fn client_id ->
        Agent.get(agent, fn state -> MapSet.member?(state.alive, client_id) end)
      end
    }

    {backend, agent}
  end

  defp starts(agent), do: Agent.get(agent, & &1.starts)
  defp stops(agent), do: Agent.get(agent, & &1.stops)

  # Arm the next `start_client` for `client_id` to fail with `reason`.
  defp arm_failure(agent, client_id, reason),
    do: Agent.update(agent, &put_in(&1.fail, Map.put(&1.fail, client_id, reason)))

  defp clear_failure(agent, client_id),
    do: Agent.update(agent, &put_in(&1.fail, Map.delete(&1.fail, client_id)))

  # Simulate a brod client that is alive but was never started via this manager —
  # e.g. one that survived a manager crash/restart (manager state reset to empty
  # while brod_sup kept the client running).
  defp simulate_orphan(agent, client_id),
    do: Agent.update(agent, &put_in(&1.alive, MapSet.put(&1.alive, client_id)))

  # --- Manager helpers ----------------------------------------------------

  defp start_manager(backend, opts \\ []) do
    opts = Keyword.merge([name: nil, backend: backend], opts)
    {:ok, pid} = Manager.start_link(opts)
    pid
  end

  defp ensure(pid, integration_id, brokers, client_config, producer_config) do
    GenServer.call(pid, {:ensure, integration_id, brokers, client_config, producer_config})
  end

  defp tracked(pid), do: :sys.get_state(pid).clients

  # A connection config that drives `Kafka.build_client_config/1` down the
  # verify_peer + match_fun branch. Rebuilt per call so each `build_client_config`
  # mints a fresh ssl `match_fun` closure instance.
  defp tls_config, do: %{security: %Ash.Union{type: :tls, value: %{verify: :verify_peer}}}

  setup do
    {backend, agent} = new_backend()
    %{backend: backend, agent: agent}
  end

  # --- Starting & tracking ------------------------------------------------

  describe "ensure_client/4 initial start" do
    test "starts a client, tracks it, and replies :ok", %{backend: backend, agent: agent} do
      pid = start_manager(backend)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      assert [start] = starts(agent)
      assert start.brokers == @brokers
      assert start.client_id == Manager.client_id_for("int-1")
      assert stops(agent) == []
      assert Map.has_key?(tracked(pid), "int-1")
    end

    test "configures auto_start_producers so any topic gets a producer (bug 1b)", %{
      backend: backend,
      agent: agent
    } do
      pid = start_manager(backend)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      assert [%{config: config}] = starts(agent)
      # The kpro TLS/SASL options are preserved...
      assert Keyword.get(config, :ssl) == [verify: :verify_peer]
      # ...and the producer config rides along as the client's default, applied to
      # EVERY topic lazily — a second subscription on a different topic no longer
      # fails with :producer_not_found because no explicit per-topic start is
      # needed.
      assert Keyword.get(config, :auto_start_producers) == true
      assert Keyword.get(config, :default_producer_config) == @producer_config
    end
  end

  describe "ensure_client/4 reuse" do
    test "an unchanged config on a live client does not restart", %{
      backend: backend,
      agent: agent
    } do
      pid = start_manager(backend)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)
      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      assert length(starts(agent)) == 1
      assert stops(agent) == []
    end
  end

  # --- Config-change restarts (bug 1a) ------------------------------------

  describe "ensure_client/4 config change" do
    test "changed brokers stop the old client and start a new one", %{
      backend: backend,
      agent: agent
    } do
      pid = start_manager(backend)
      client_id = Manager.client_id_for("int-1")

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)
      new_brokers = [{~c"broker-2", 9093}]
      assert :ok = ensure(pid, "int-1", new_brokers, @client_config, @producer_config)

      assert stops(agent) == [client_id]
      assert [_first, second] = starts(agent)
      assert second.brokers == new_brokers
    end

    test "rotated SASL credentials restart the client with the new config (bug 1a)", %{
      backend: backend,
      agent: agent
    } do
      pid = start_manager(backend)

      old = [sasl: {:plain, "user", "old-secret"}]
      new = [sasl: {:plain, "user", "rotated-secret"}]

      assert :ok = ensure(pid, "int-1", @brokers, old, @producer_config)
      assert :ok = ensure(pid, "int-1", @brokers, new, @producer_config)

      assert stops(agent) == [Manager.client_id_for("int-1")]
      assert [_first, second] = starts(agent)
      assert Keyword.get(second.config, :sasl) == {:plain, "user", "rotated-secret"}
    end

    test "changed producer config (acks) restarts the client", %{backend: backend, agent: agent} do
      pid = start_manager(backend)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, required_acks: -1)
      assert :ok = ensure(pid, "int-1", @brokers, @client_config, required_acks: 1)

      assert length(starts(agent)) == 2
      assert stops(agent) == [Manager.client_id_for("int-1")]
    end
  end

  # --- Orphan adoption after a manager restart (bug 2) --------------------

  describe "ensure_client/4 orphan adoption" do
    test "an alive-but-untracked client is stopped and restarted under current config", %{
      backend: backend,
      agent: agent
    } do
      pid = start_manager(backend)
      client_id = Manager.client_id_for("int-1")

      # A brod client that survived a manager crash: alive, but the manager has no
      # record of it (and no idea what config it carries).
      simulate_orphan(agent, client_id)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      # Adopted by tearing it down first, then starting fresh with the known config.
      assert stops(agent) == [client_id]
      assert [%{client_id: ^client_id}] = starts(agent)
      assert Map.has_key?(tracked(pid), "int-1")
    end
  end

  # --- Start failures leave nothing orphaned (bug 2) ----------------------

  describe "ensure_client/4 start failure" do
    test "a failed start replies error and records no client", %{backend: backend, agent: agent} do
      pid = start_manager(backend)
      client_id = Manager.client_id_for("int-1")
      arm_failure(agent, client_id, :nxdomain)

      assert {:error, :nxdomain} =
               ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      # Nothing tracked (so idle cleanup has nothing to leak) and no alive client
      # left behind (the fake only marks alive on a successful start).
      assert tracked(pid) == %{}
      refute backend.alive?.(client_id)
    end

    test "a later ensure retries the start instead of short-circuiting", %{
      backend: backend,
      agent: agent
    } do
      pid = start_manager(backend)
      client_id = Manager.client_id_for("int-1")
      arm_failure(agent, client_id, :nxdomain)

      assert {:error, :nxdomain} =
               ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      # The broker recovers; the next delivery must actually try again (the old bug
      # would see a half-started client "alive" and never start the producer).
      clear_failure(agent, client_id)
      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      assert length(starts(agent)) == 2
      assert Map.has_key?(tracked(pid), "int-1")
    end
  end

  # --- Idle teardown & the cleanup/produce race (bug 3) -------------------

  describe "idle cleanup" do
    test "a recently-ensured client survives cleanup (synchronous activity, bug 3)", %{
      backend: backend,
      agent: agent
    } do
      # A large idle timeout: the client was just ensured, so it must not be torn
      # down. Because ensure records activity synchronously (not via an async
      # cast), a cleanup running right after ensure sees a fresh timestamp — the
      # window where cleanup could stop the client between ensure returning :ok and
      # the caller's produce is closed.
      pid = start_manager(backend, idle_timeout_ms: 60_000)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)
      send(pid, :cleanup)

      assert Map.has_key?(tracked(pid), "int-1")
      assert stops(agent) == []
    end

    test "an idle client is stopped and forgotten", %{backend: backend, agent: agent} do
      pid = start_manager(backend, idle_timeout_ms: 0)
      client_id = Manager.client_id_for("int-1")

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)

      # Advance monotonic time so the entry is strictly older than the (zero) idle
      # window, then run cleanup.
      Process.sleep(2)
      send(pid, :cleanup)

      assert tracked(pid) == %{}
      assert client_id in stops(agent)
    end

    test "a forgotten client is started fresh on the next ensure", %{
      backend: backend,
      agent: agent
    } do
      pid = start_manager(backend, idle_timeout_ms: 0)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)
      Process.sleep(2)
      send(pid, :cleanup)
      assert tracked(pid) == %{}

      before = length(starts(agent))
      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)
      assert length(starts(agent)) == before + 1
    end
  end

  # --- touch --------------------------------------------------------------

  describe "touch/1 semantics" do
    test "touch refreshes a tracked client's last_active", %{backend: backend} do
      pid = start_manager(backend, idle_timeout_ms: 60_000)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)
      before = tracked(pid)["int-1"].last_active

      Process.sleep(2)
      GenServer.cast(pid, {:touch, "int-1"})
      # Flush the cast before reading.
      after_ts = :sys.get_state(pid).clients["int-1"].last_active

      assert after_ts > before
    end

    test "touch for an unknown integration is a no-op", %{backend: backend, agent: agent} do
      pid = start_manager(backend, idle_timeout_ms: 60_000)

      GenServer.cast(pid, {:touch, "does-not-exist"})

      assert :sys.get_state(pid).clients == %{}
      assert starts(agent) == []
      assert stops(agent) == []
    end
  end

  # --- Two integrations are independent -----------------------------------

  describe "multiple integrations" do
    test "each integration gets its own client keyed by id", %{backend: backend, agent: agent} do
      pid = start_manager(backend)

      assert :ok = ensure(pid, "int-1", @brokers, @client_config, @producer_config)
      assert :ok = ensure(pid, "int-2", @brokers, @client_config, @producer_config)

      client_ids = Enum.map(starts(agent), & &1.client_id)
      assert Manager.client_id_for("int-1") in client_ids
      assert Manager.client_id_for("int-2") in client_ids
      assert map_size(tracked(pid)) == 2
    end
  end

  # --- Fingerprint stability across the real TLS match_fun closure --------

  # The reuse path ("unchanged config ⇒ don't restart") rests on the SAME effective
  # config fingerprinting identically on every delivery. The one part of the config
  # that could serialize differently per call is the ssl `match_fun` — an anonymous
  # closure the transport bakes into `client_config`. The other reuse tests use a
  # hand-written `[ssl: [verify: :verify_peer]]` that has no closure, so they don't
  # cover the config that actually ships. These do: they run the REAL
  # `Kafka.build_client_config/1` output (which carries
  # `:public_key.pkix_verify_hostname_match_fun(:https)`) through the manager, and a
  # *freshly rebuilt* config on the second ensure so a new closure instance is what
  # has to fingerprint the same. If a future TLS-opts change introduces a per-call
  # closure (a `verify_fun` capturing a fresh binary, an `sni_fun`, a timestamp),
  # these fail instead of prod silently restarting the client on every produce.
  describe "fingerprint stability across the real TLS match_fun closure" do
    test "a freshly-rebuilt client_config is treated as unchanged (no restart)", %{
      backend: backend,
      agent: agent
    } do
      {:ok, client_config} = Kafka.build_client_config(tls_config())
      # Sanity check: the config really does carry the match_fun closure this test
      # exists to pin down — otherwise it would silently prove nothing.
      assert [ssl: ssl] = client_config
      assert is_function(get_in(ssl, [:customize_hostname_check])[:match_fun])

      pid = start_manager(backend)
      assert :ok = ensure(pid, "int-1", @brokers, client_config, @producer_config)

      # A second ensure with a freshly-rebuilt config (new closure instance) must be
      # treated as UNCHANGED — reuse the live client, no stop/start.
      {:ok, client_config_2} = Kafka.build_client_config(tls_config())
      assert :ok = ensure(pid, "int-1", @brokers, client_config_2, @producer_config)

      assert length(starts(agent)) == 1
      assert stops(agent) == []
    end

    test "a genuinely different TLS config still restarts", %{backend: backend, agent: agent} do
      {:ok, verify_peer} = Kafka.build_client_config(tls_config())

      {:ok, verify_none} =
        Kafka.build_client_config(%{
          security: %Ash.Union{type: :tls, value: %{verify: :verify_none}}
        })

      pid = start_manager(backend)
      assert :ok = ensure(pid, "int-1", @brokers, verify_peer, @producer_config)
      assert :ok = ensure(pid, "int-1", @brokers, verify_none, @producer_config)

      # The closure stability must not be so coarse that it masks a real change.
      assert length(starts(agent)) == 2
      assert stops(agent) == [Manager.client_id_for("int-1")]
    end
  end
end
