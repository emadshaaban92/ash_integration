defmodule AshIntegration.Transport.OAuth2.TokenCache do
  @moduledoc """
  Per-credential OAuth2 access-token cache with single-flight fetching.

  Broadway delivers many events per connection **concurrently**, so N in-flight
  deliveries sharing a credential must not each hit the token endpoint. This
  process coalesces them: the first caller for a cold key becomes the **leader**
  and performs the fetch (in its own process, so per-process HTTP test stubs stay
  visible); every other caller that arrives while it is in flight **waits** and is
  handed the leader's result. A valid token is cached (in an ETS table with read
  concurrency) and reused until a refresh skew before its expiry.

  Cache entries are keyed by a hash that includes the (decrypted) `client_secret`,
  so a rotated secret produces a new key and transparently invalidates the old
  token. Expired/idle entries are swept on an interval, mirroring
  `AshIntegration.Transport.KafkaClientManager`'s idle-teardown model
  (`:oauth2_idle_timeout_ms`).
  """

  use GenServer

  require Logger

  alias AshIntegration.Transport.OAuth2

  @table __MODULE__

  # Ceiling on a token's effective lifetime, regardless of the server-reported
  # `expires_in`. A buggy or hostile IdP returning a huge `expires_in` would
  # otherwise pin a token far past real server-side revocation AND defeat the idle
  # sweeper for that key (its `expires_at` would never fall below the sweep
  # cutoff). Clamp the TTL so a stale/over-long token is re-fetched within a day.
  @max_token_ttl_ms :timer.hours(24)

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return a valid access token for `descriptor`, cached under `key`.

  Fast path: a fresh cached token is returned without touching the GenServer.
  Otherwise this coordinates a single-flight fetch — leading it, or waiting for
  the in-flight leader — via `OAuth2.request_token/1`.
  """
  @spec get_token(binary(), OAuth2.descriptor()) :: {:ok, String.t()} | {:error, map()}
  def get_token(key, descriptor) do
    case cached(key) do
      {:ok, _token} = hit -> hit
      :miss -> coordinate(key, descriptor)
    end
  end

  @doc "Drop all cached tokens and in-flight state. Intended for tests."
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  defp coordinate(key, descriptor) do
    # A unique per-request ref tags the leader's reply so a *stale* reply — one
    # deposited into this (long-lived Broadway worker) process's mailbox after an
    # earlier wait on the same key timed out — can never be mistaken for the result
    # of THIS wait. Matching on the shared `key` would let an hours-old token/error
    # match instantly; a fresh ref each request rules that out.
    ref = make_ref()

    case GenServer.call(__MODULE__, {:acquire, key, ref}, wait_timeout_ms()) do
      {:hit, token} ->
        {:ok, token}

      :lead ->
        result = OAuth2.request_token(descriptor)
        GenServer.call(__MODULE__, {:complete, key, result})
        finalize(result)

      :wait ->
        await_leader(key, ref)
    end
  end

  defp await_leader(key, ref) do
    wait_timeout_ms = wait_timeout_ms()

    receive do
      {:oauth2_token, ^ref, result} -> finalize(result)
    after
      wait_timeout_ms ->
        # Deregister this waiter so the leader doesn't later `send` its reply into a
        # long-lived Broadway worker's mailbox (where it would surface as unexpected
        # `handle_info` noise). The cancel and the leader's completion are both
        # serialized through the GenServer, so exactly one of two things is true
        # afterwards: either we were removed before completion (no reply sent), or
        # completion already ran and a reply for THIS ref is in our mailbox — the
        # zero-timeout drain below discards that one so nothing lingers.
        GenServer.call(__MODULE__, {:cancel_wait, key, ref})
        drain_stale_reply(ref)

        Logger.warning(
          "OAuth2 TokenCache: timed out after #{wait_timeout_ms}ms waiting for an " <>
            "in-flight token fetch; failing this delivery (retryable)"
        )

        {:error,
         %{
           failure_class: :transport,
           error_message: "Timed out waiting for an in-flight OAuth2 token fetch",
           retryable: true
         }}
    end
  end

  defp drain_stale_reply(ref) do
    receive do
      {:oauth2_token, ^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  # A successful fetch returns the token to the caller; a classified failure is
  # passed straight through (never cached).
  defp finalize({:ok, %{token: token}}), do: {:ok, token}
  defp finalize({:error, _reason} = error), do: error

  # ── ETS fast path ─────────────────────────────────────────────────────────

  defp cached(key) do
    case :ets.lookup(@table, key) do
      [{^key, token, refresh_at, _expires_at}] ->
        if now() < refresh_at, do: {:ok, token}, else: :miss

      _ ->
        :miss
    end
  rescue
    # The table may not exist yet if the cache process hasn't booted (e.g. a
    # transport invoked before the supervisor started). Treat as a miss and let
    # the GenServer.call surface a clear error.
    ArgumentError -> :miss
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{inflight: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, key, req_ref}, {caller_pid, _tag}, state) do
    case cached(key) do
      {:ok, token} ->
        # Filled by a leader while this caller was en route to the GenServer.
        {:reply, {:hit, token}, state}

      :miss ->
        if Map.has_key?(state.inflight, key) do
          # Remember each waiter WITH its per-request ref, so the completion reply is
          # addressed to this specific wait and a timed-out earlier wait's stale
          # message can't satisfy it.
          state = update_in(state.inflight[key].waiters, &[{caller_pid, req_ref} | &1])
          {:reply, :wait, state}
        else
          ref = Process.monitor(caller_pid)

          state =
            state
            |> put_in([:inflight, key], %{leader: caller_pid, ref: ref, waiters: []})
            |> put_in([:monitors, ref], key)

          {:reply, :lead, state}
        end
    end
  end

  def handle_call({:cancel_wait, key, req_ref}, _from, state) do
    # Drop a timed-out waiter (identified by its per-request ref) from the key's
    # waiters list so `notify_and_clear` no longer sends it a reply. A no-op if the
    # key already completed and cleared.
    state =
      case state.inflight do
        %{^key => %{waiters: waiters} = entry} ->
          put_in(state.inflight[key], %{entry | waiters: List.keydelete(waiters, req_ref, 1)})

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:complete, key, result}, _from, state) do
    {:reply, :ok, resolve(state, key, result)}
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@table)

    for {_key, %{ref: ref}} <- state.inflight do
      Process.demonitor(ref, [:flush])
    end

    {:reply, :ok, %{state | inflight: %{}, monitors: %{}}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # A leader died before reporting its result — fail its waiters (retryable)
    # and clear the key so the next request can lead a fresh fetch.
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {key, monitors} ->
        Logger.warning(
          "OAuth2 TokenCache: token-fetch leader exited before completing " <>
            "(#{inspect(reason)}); failing its waiters (retryable)"
        )

        error =
          {:error,
           %{
             failure_class: :transport,
             error_message: "OAuth2 token fetch process exited before completing",
             retryable: true
           }}

        state = %{state | monitors: monitors}
        {:noreply, notify_and_clear(state, key, error)}
    end
  end

  def handle_info(:cleanup, state) do
    cutoff = now() - idle_timeout_ms()

    # Match expired-and-idle entries: `expires_at < cutoff`. `:ets.select_delete`
    # with a guard on the 4th element (expires_at).
    :ets.select_delete(@table, [
      {{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  # Store the token (on success), then notify every waiter and drop the in-flight
  # entry. Demonitors the leader.
  defp resolve(state, key, result) do
    case result do
      {:ok, %{token: token, expires_in: expires_in}} ->
        store(key, token, expires_in)

      {:error, _reason} ->
        :ok
    end

    case Map.get(state.inflight, key) do
      %{ref: ref} -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    notify_and_clear(state, key, result)
  end

  defp notify_and_clear(state, key, result) do
    case Map.pop(state.inflight, key) do
      {nil, _inflight} ->
        state

      {%{ref: ref, waiters: waiters}, inflight} ->
        for {pid, req_ref} <- waiters, do: send(pid, {:oauth2_token, req_ref, result})
        %{state | inflight: inflight, monitors: Map.delete(state.monitors, ref)}
    end
  end

  defp store(key, token, expires_in) do
    now = now()
    # Clamp the server-reported lifetime to a sane ceiling (see @max_token_ttl_ms)
    # before deriving expires_at/refresh_at, so a bogus giant `expires_in` can't
    # pin a token indefinitely or starve the idle sweeper.
    ttl_ms = min(expires_in * 1000, @max_token_ttl_ms)
    expires_at = now + ttl_ms
    # Refresh a skew before expiry — but never let the skew exceed HALF the token's
    # lifetime. Otherwise a short-lived token (`expires_in <= skew`, including the
    # 60s default the provider uses when the endpoint omits `expires_in`) would put
    # `refresh_at` at or behind `now` and never be cached at all: every delivery
    # would re-fetch. Capping at half the lifetime guarantees a positive cache window.
    skew = min(refresh_skew_ms(), div(ttl_ms, 2))
    refresh_at = expires_at - skew
    :ets.insert(@table, {key, token, refresh_at, expires_at})
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, check_interval_ms())

  defp now, do: System.monotonic_time(:millisecond)

  # ── Host-tunable timings ──────────────────────────────────────────────────────
  # Read at RUNTIME (`Application.get_env`) so a release's `runtime.exs` config is
  # honoured rather than baked in at compile time. Each is a cheap ETS-backed
  # lookup on a code path that already does I/O (token store / idle sweep).

  # How long before a token's expiry to refresh it, so a token doesn't expire
  # mid-flight between the cache read and the wire send.
  defp refresh_skew_ms, do: Application.get_env(:ash_integration, :oauth2_refresh_skew_ms, 60_000)

  # An idle entry (expired and untouched) is swept after this long, bounding
  # memory for credentials that stop being used. Mirrors `:kafka_idle_timeout_ms`.
  defp idle_timeout_ms,
    do: Application.get_env(:ash_integration, :oauth2_idle_timeout_ms, 300_000)

  defp check_interval_ms, do: div(idle_timeout_ms(), 2)

  # How long a waiter blocks for the leader's fetch result before giving up.
  defp wait_timeout_ms, do: Application.get_env(:ash_integration, :oauth2_wait_timeout_ms, 30_000)
end
