defmodule AshIntegration.Transport.KafkaClientManager.BrodBackend do
  @moduledoc false
  # The real `:brod` interaction boundary for `KafkaClientManager`.
  #
  # Every broker-touching call the manager makes goes through one of these three
  # functions, injected into the manager as its `:backend` (a
  # `%{start_client:, stop_client:, alive?:}` map of arity-3/1/1 funs). Production
  # uses this module; tests inject a fake that simulates client liveness and start
  # failures, so the manager's lifecycle state machine (config-change restart,
  # orphan adoption, idle teardown) can be exercised without a running broker.

  @doc """
  Start a brod client under `brod_sup`. Returns `:ok` or `{:error, reason}`; a
  failure adds no supervised child, so there is nothing to clean up.
  """
  @spec start_client([{charlist(), non_neg_integer()}], atom(), keyword()) ::
          :ok | {:error, term()}
  def start_client(brokers, client_id, config), do: :brod.start_client(brokers, client_id, config)

  @doc """
  Stop (and forget) a brod client. Idempotent — stopping an absent client is a
  no-op — so it is safe to call before a restart or on an orphan of unknown state.
  """
  @spec stop_client(atom()) :: :ok
  def stop_client(client_id) do
    _ = :brod.stop_client(client_id)
    :ok
  end

  @doc """
  Whether the brod client process registered under `client_id` is alive. brod
  registers its client under the client-id atom, so this is a direct
  `Process.whereis/1` — it sees clients that survived a manager restart (orphans)
  as well as ones the manager itself started.
  """
  @spec alive?(atom()) :: boolean()
  def alive?(client_id) do
    case Process.whereis(client_id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end
end
