defmodule AshIntegration.KafkaClientManager do
  @moduledoc """
  Manages brod client lifecycle for Kafka integrations.

  One brod client is maintained per outbound integration, keyed by integration ID.
  Clients are started on first delivery and torn down after an idle timeout.
  """

  use GenServer

  require Logger

  @idle_timeout_ms Application.compile_env(:ash_integration, :kafka_idle_timeout_ms, 300_000)
  @check_interval_ms div(@idle_timeout_ms, 2)

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures a brod client is running for the given integration.
  Starts one if it doesn't exist. Returns `:ok` or `{:error, reason}`.
  """
  @spec ensure_client(
          String.t(),
          [{binary(), non_neg_integer()}],
          keyword(),
          String.t(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def ensure_client(integration_id, brokers, client_config, topic, producer_config \\ []) do
    client_id = client_id_for(integration_id)

    if client_alive?(client_id) do
      touch(integration_id)
      :ok
    else
      GenServer.call(
        __MODULE__,
        {:start_client, integration_id, brokers, client_config, topic, producer_config}
      )
    end
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
  @spec client_id_for(String.t()) :: atom()
  def client_id_for(integration_id) do
    :"ash_kafka_#{integration_id}"
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    if AshIntegration.Transport.available?(:kafka) do
      schedule_cleanup()
      {:ok, %{clients: %{}}}
    else
      :ignore
    end
  end

  @impl true
  def handle_call(
        {:start_client, integration_id, brokers, client_config, topic, producer_config},
        _from,
        state
      ) do
    client_id = client_id_for(integration_id)

    if client_alive?(client_id) do
      state = put_in(state, [:clients, integration_id], now())
      {:reply, :ok, state}
    else
      with :ok <- :brod.start_client(brokers, client_id, client_config),
           :ok <- :brod.start_producer(client_id, topic, producer_config) do
        state = put_in(state, [:clients, integration_id], now())
        {:reply, :ok, state}
      else
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_cast({:touch, integration_id}, state) do
    if Map.has_key?(state.clients, integration_id) do
      {:noreply, put_in(state, [:clients, integration_id], now())}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = now() - @idle_timeout_ms

    {expired, active} =
      Enum.split_with(state.clients, fn {_id, last_active} -> last_active < cutoff end)

    for {integration_id, _} <- expired do
      client_id = client_id_for(integration_id)

      Logger.info("Stopping idle Kafka client for integration #{integration_id}")
      :brod.stop_client(client_id)
    end

    schedule_cleanup()
    {:noreply, %{state | clients: Map.new(active)}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @check_interval_ms)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp client_alive?(client_id) do
    case Process.whereis(client_id) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end
end
