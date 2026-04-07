defmodule AshIntegration.Transports.Grpc.Channel do
  @moduledoc """
  Manages a persistent HTTP/2 connection for a single gRPC integration.

  One process per outbound integration, started on demand via
  `ChannelSupervisor` and registered in `ChannelRegistry`. The process
  terminates itself after an idle timeout.
  """

  use GenServer

  require Logger

  alias AshIntegration.Transports.Grpc.ChannelSupervisor

  @idle_timeout_ms Application.compile_env(
                     :ash_integration,
                     :grpc_idle_timeout_ms,
                     300_000
                   )

  @default_recv_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns `{:ok, pid}` for the channel process for this integration,
  starting one if it doesn't exist yet.
  """
  @spec get_or_connect(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def get_or_connect(integration_id, config) do
    case lookup(integration_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_channel(integration_id, config)
    end
  end

  @doc """
  Performs a gRPC unary call over the managed HTTP/2 connection.

  Returns `{:ok, %{status: integer, message: binary, body: binary}}` on
  success or `{:error, reason}` on failure.
  """
  @spec unary_call(
          pid(),
          String.t(),
          binary(),
          [{binary(), binary()}],
          non_neg_integer()
        ) ::
          {:ok, %{status: non_neg_integer(), message: binary(), body: binary()}}
          | {:error, term()}
  def unary_call(pid, path, encoded_body, metadata \\ [], timeout_ms \\ @default_recv_timeout_ms) do
    GenServer.call(
      pid,
      {:unary_call, path, encoded_body, metadata, timeout_ms},
      timeout_ms + 5_000
    )
  end

  # ---------------------------------------------------------------------------
  # Start / Registry
  # ---------------------------------------------------------------------------

  def start_link({integration_id, config}) do
    GenServer.start_link(__MODULE__, {integration_id, config}, name: via(integration_id))
  end

  defp via(integration_id) do
    {:via, Registry, {ChannelSupervisor.registry(), integration_id}}
  end

  defp lookup(integration_id) do
    case Registry.lookup(ChannelSupervisor.registry(), integration_id) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :not_found

      [] ->
        :not_found
    end
  end

  defp start_channel(integration_id, config) do
    spec = {__MODULE__, {integration_id, config}}

    case DynamicSupervisor.start_child(ChannelSupervisor.dynamic_supervisor(), spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({integration_id, config}) do
    case do_connect(config) do
      {:ok, conn} ->
        state = %{
          integration_id: integration_id,
          config: config,
          conn: conn,
          last_activity: now()
        }

        schedule_idle_check()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:unary_call, path, encoded_body, metadata, timeout_ms}, _from, state) do
    state = ensure_connected(state)

    case state.conn do
      nil ->
        {:reply, {:error, :connection_failed}, state}

      conn ->
        grpc_frame = <<0::8, byte_size(encoded_body)::32>> <> encoded_body

        headers =
          [
            {"content-type", "application/grpc+proto"},
            {"te", "trailers"}
          ] ++ metadata

        case Mint.HTTP2.request(conn, "POST", path, headers, grpc_frame) do
          {:ok, conn, request_ref} ->
            state = %{state | conn: conn, last_activity: now()}

            case recv_response(conn, request_ref, timeout_ms) do
              {:ok, conn, response} ->
                {:reply, {:ok, response}, %{state | conn: conn}}

              {:error, conn, reason} ->
                {:reply, {:error, reason}, %{state | conn: conn}}
            end

          {:error, conn, reason} ->
            {:reply, {:error, reason}, %{state | conn: conn}}
        end
    end
  end

  @impl true
  def handle_info(:idle_check, state) do
    idle_ms = now() - state.last_activity

    if idle_ms >= @idle_timeout_ms do
      Logger.info("Closing idle gRPC connection for integration #{state.integration_id}")

      if state.conn, do: Mint.HTTP2.close(state.conn)
      {:stop, :normal, state}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.debug(
      "gRPC Channel #{state.integration_id} received unexpected message: #{inspect(message)}"
    )

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Connection management
  # ---------------------------------------------------------------------------

  defp ensure_connected(%{conn: conn} = state) when not is_nil(conn) do
    if Mint.HTTP2.open?(conn) do
      state
    else
      reconnect(state)
    end
  end

  defp ensure_connected(state), do: reconnect(state)

  defp reconnect(state) do
    case do_connect(state.config) do
      {:ok, conn} -> %{state | conn: conn}
      {:error, _} -> %{state | conn: nil}
    end
  end

  defp do_connect(config) do
    {host, port, scheme} = parse_endpoint(config)

    case scheme do
      :http ->
        Mint.HTTP2.connect(:http, host, port, mode: :passive)

      :https ->
        transport_opts = build_transport_opts(Map.get(config, :security))

        opts =
          [mode: :passive] ++
            if(transport_opts == [], do: [], else: [transport_opts: transport_opts])

        Mint.HTTP2.connect(:https, host, port, opts)
    end
  end

  defp parse_endpoint(%{endpoint: endpoint} = config) do
    security = Map.get(config, :security)

    {host, port_string} =
      case String.split(endpoint, ":", parts: 2) do
        [h, p] -> {h, p}
        [h] -> {h, nil}
      end

    scheme = connection_scheme(security)

    default_port =
      case scheme do
        :https -> 443
        :http -> 80
      end

    port =
      case port_string do
        nil -> default_port
        p -> String.to_integer(p)
      end

    {host, port, scheme}
  end

  defp connection_scheme(%Ash.Union{type: :none}), do: :http
  defp connection_scheme(%Ash.Union{type: :tls}), do: :https
  defp connection_scheme(%Ash.Union{type: :bearer_token}), do: :https
  defp connection_scheme(%Ash.Union{type: :mutual_tls}), do: :https
  defp connection_scheme(nil), do: :http

  defp build_transport_opts(%Ash.Union{type: :mutual_tls, value: mtls}) do
    cert_der = pem_to_der(mtls.client_cert_pem)
    key_der = pem_to_der_key(mtls.client_key_pem)

    [cert: cert_der, key: key_der]
  end

  defp build_transport_opts(_), do: []

  defp pem_to_der(pem_string) do
    [entry | _] = :public_key.pem_decode(pem_string)
    :public_key.pem_entry_decode(entry)
  end

  defp pem_to_der_key(pem_string) do
    [entry | _] = :public_key.pem_decode(pem_string)
    decoded = :public_key.pem_entry_decode(entry)

    case entry do
      {type, der_bytes, :not_encrypted} -> {ssl_key_type(type), der_bytes}
      _ -> decoded
    end
  end

  defp ssl_key_type(:RSAPrivateKey), do: :RSAPrivateKey
  defp ssl_key_type(:ECPrivateKey), do: :ECPrivateKey
  defp ssl_key_type(:PrivateKeyInfo), do: :PrivateKeyInfo
  defp ssl_key_type(other), do: other

  # ---------------------------------------------------------------------------
  # Response collection
  # ---------------------------------------------------------------------------

  defp recv_response(conn, request_ref, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_recv_response(conn, request_ref, deadline, %{headers: [], data: <<>>, trailers: []})
  end

  defp do_recv_response(conn, request_ref, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, conn, :timeout}
    else
      recv_timeout = min(remaining, 5_000)

      case Mint.HTTP2.recv(conn, 0, recv_timeout) do
        {:ok, conn, []} ->
          do_recv_response(conn, request_ref, deadline, acc)

        {:ok, conn, responses} ->
          {conn, acc, done?} = process_responses(conn, request_ref, responses, acc)

          if done? do
            {:ok, conn, build_grpc_response(acc)}
          else
            do_recv_response(conn, request_ref, deadline, acc)
          end

        {:error, conn, %Mint.TransportError{reason: :timeout}, _responses} ->
          do_recv_response(conn, request_ref, deadline, acc)

        {:error, conn, reason, _responses} ->
          {:error, conn, reason}
      end
    end
  end

  defp process_responses(conn, request_ref, responses, acc) do
    Enum.reduce(responses, {conn, acc, false}, fn
      {:status, ^request_ref, _status}, {conn, acc, done?} ->
        {conn, acc, done?}

      {:headers, ^request_ref, headers}, {conn, acc, done?} ->
        if acc.data == <<>> and acc.trailers == [] do
          {conn, %{acc | headers: acc.headers ++ headers}, done?}
        else
          {conn, %{acc | trailers: acc.trailers ++ headers}, done?}
        end

      {:data, ^request_ref, data}, {conn, acc, done?} ->
        {conn, %{acc | data: acc.data <> data}, done?}

      {:done, ^request_ref}, {conn, acc, _done?} ->
        {conn, acc, true}

      _other, {conn, acc, done?} ->
        {conn, acc, done?}
    end)
  end

  defp build_grpc_response(acc) do
    all_headers = acc.headers ++ acc.trailers

    grpc_status =
      case List.keyfind(all_headers, "grpc-status", 0) do
        {_, value} -> String.to_integer(value)
        nil -> 0
      end

    grpc_message =
      case List.keyfind(all_headers, "grpc-message", 0) do
        {_, value} -> URI.decode(value)
        nil -> ""
      end

    body =
      case acc.data do
        <<_compressed::8, _length::32, payload::binary>> -> payload
        other -> other
      end

    %{status: grpc_status, message: grpc_message, body: body}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, div(@idle_timeout_ms, 2))
  end

  defp now, do: System.monotonic_time(:millisecond)
end
