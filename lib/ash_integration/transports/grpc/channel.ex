defmodule AshIntegration.Transports.Grpc.Channel do
  @moduledoc """
  Manages persistent HTTP/2 connections for gRPC transport.

  One Mint.HTTP2 connection is maintained per outbound integration, keyed by
  integration ID. Connections are established on first use and torn down after
  an idle timeout.
  """

  use GenServer

  require Logger

  @idle_timeout_ms Application.compile_env(
                     :ash_integration,
                     :grpc_idle_timeout_ms,
                     300_000
                   )
  @check_interval_ms div(@idle_timeout_ms, 2)

  @default_recv_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `{:ok, pid}` for the channel GenServer after ensuring a connection
  exists for `integration_id`. Creates a new connection when one does not
  already exist or the previous one has been closed.

  `config` is a map with at least:
    - `:endpoint` — `"host:port"` string
    - `:security` — one of the `AshIntegration.GrpcSecurity.*` structs
  """
  @spec get_or_connect(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def get_or_connect(integration_id, config) do
    case GenServer.call(__MODULE__, {:get_or_connect, integration_id, config}) do
      :ok -> {:ok, Process.whereis(__MODULE__)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Performs a gRPC unary call over the managed HTTP/2 connection for the given
  integration.

  `metadata` is a list of `{key, value}` header tuples.

  Returns `{:ok, %{status: integer, message: binary, body: binary}}` on
  success or `{:error, reason}` on failure.
  """
  @spec unary_call(
          pid(),
          String.t(),
          String.t(),
          binary(),
          [{binary(), binary()}],
          non_neg_integer()
        ) ::
          {:ok, %{status: non_neg_integer(), message: binary(), body: binary()}}
          | {:error, term()}
  def unary_call(
        pid,
        integration_id,
        path,
        encoded_body,
        metadata \\ [],
        timeout_ms \\ @default_recv_timeout_ms
      ) do
    GenServer.call(
      pid,
      {:unary_call, integration_id, path, encoded_body, metadata, timeout_ms},
      timeout_ms + 5_000
    )
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{connections: %{}}}
  end

  @impl true
  def handle_call({:get_or_connect, integration_id, config}, _from, state) do
    case Map.get(state.connections, integration_id) do
      %{conn: conn} = entry when not is_nil(conn) ->
        if Mint.HTTP2.open?(conn) do
          entry = %{entry | last_activity: now()}
          state = put_in(state, [:connections, integration_id], entry)
          {:reply, :ok, state}
        else
          case do_connect(config) do
            {:ok, conn} ->
              entry = %{conn: conn, last_activity: now()}
              state = put_in(state, [:connections, integration_id], entry)
              {:reply, :ok, state}

            {:error, reason} ->
              state = %{state | connections: Map.delete(state.connections, integration_id)}
              {:reply, {:error, reason}, state}
          end
        end

      _ ->
        case do_connect(config) do
          {:ok, conn} ->
            entry = %{conn: conn, last_activity: now()}
            state = put_in(state, [:connections, integration_id], entry)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:unary_call, integration_id, path, encoded_body, metadata, timeout_ms},
        _from,
        state
      ) do
    entry = Map.get(state.connections, integration_id)

    if is_nil(entry) do
      {:reply, {:error, :no_connection}, state}
    else
      grpc_frame = <<0::8, byte_size(encoded_body)::32>> <> encoded_body

      # Mint adds :method, :path, :scheme, :authority pseudo-headers automatically
      headers =
        [
          {"content-type", "application/grpc+proto"},
          {"te", "trailers"}
        ] ++ metadata

      case Mint.HTTP2.request(entry.conn, "POST", path, headers, grpc_frame) do
        {:ok, conn, request_ref} ->
          entry = %{entry | conn: conn, last_activity: now()}
          state = put_in(state, [:connections, integration_id], entry)

          case recv_response(conn, request_ref, timeout_ms) do
            {:ok, conn, response} ->
              entry = %{entry | conn: conn}
              state = put_in(state, [:connections, integration_id], entry)
              {:reply, {:ok, response}, state}

            {:error, conn, reason} ->
              entry = %{entry | conn: conn}
              state = put_in(state, [:connections, integration_id], entry)
              {:reply, {:error, reason}, state}
          end

        {:error, conn, reason} ->
          entry = %{entry | conn: conn}
          state = put_in(state, [:connections, integration_id], entry)
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = now() - @idle_timeout_ms

    {expired, active} =
      Enum.split_with(state.connections, fn {_id, entry} ->
        entry.last_activity < cutoff
      end)

    for {integration_id, entry} <- expired do
      Logger.info("Closing idle gRPC connection for integration #{integration_id}")
      Mint.HTTP2.close(entry.conn)
    end

    schedule_cleanup()
    {:noreply, %{state | connections: Map.new(active)}}
  end

  def handle_info(message, state) do
    # In passive mode, we shouldn't receive TCP/SSL messages normally.
    # Log unexpected messages for debugging.
    Logger.debug("gRPC Channel received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Connection establishment
  # ---------------------------------------------------------------------------

  defp do_connect(config) do
    {host, port, scheme} = parse_endpoint(config)

    result =
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

    case result do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
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

  # Security is wrapped in Ash.Union: %Ash.Union{type: :none, value: %GrpcSecurity.None{}}
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

    # Return in the format Mint/ssl expects: {:type, der_binary}
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
          # No data yet, keep waiting
          do_recv_response(conn, request_ref, deadline, acc)

        {:ok, conn, responses} ->
          {conn, acc, done?} = process_responses(conn, request_ref, responses, acc)

          if done? do
            {:ok, conn, build_grpc_response(acc)}
          else
            do_recv_response(conn, request_ref, deadline, acc)
          end

        {:error, conn, %Mint.TransportError{reason: :timeout}, _responses} ->
          # Recv timeout, keep waiting if we have time left
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
        # Could be initial headers or trailers. We accumulate both.
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

    # Strip the 5-byte gRPC frame prefix from response body
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

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @check_interval_ms)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
