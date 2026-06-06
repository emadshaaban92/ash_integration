defmodule AshIntegration.Transport.HttpPinContractTest do
  @moduledoc """
  Locks down the Req/Finch/Mint behaviour that `AshIntegration.Transport.Egress.pin/1`
  relies on for its DNS-rebinding defense: given a URL whose host is a literal IP
  plus `connect_options: [hostname: H]`, the client must

    * connect to that IP (not re-resolve a name),
    * send `Host: H` (the hostname, never the connected IP), and
    * over TLS, verify the certificate against `H` (via SNI), not the IP.

  These drive REAL sockets (no `Req.Test` plug bypass) against loopback servers, so
  a blind Req/Finch/Mint upgrade that changes any of this fails here instead of
  silently turning the pin into an unverified/misrouted request in production.
  """
  use ExUnit.Case, async: false

  @hostname "webhook.test"

  setup do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  test "plain HTTP: connects to the pinned IP and sends Host: <hostname>" do
    {port, await} = start_tcp_server!()

    assert {:ok, %{status: 200}} =
             Req.request(
               url: "http://127.0.0.1:#{port}/webhook",
               method: :post,
               body: "x",
               connect_options: [hostname: @hostname],
               retry: false,
               redirect: false
             )

    raw = await.()
    # (c) Host is the hostname (a :port suffix is fine), never the connected IP.
    assert host_only(raw) == @hostname
    refute raw =~ "127.0.0.1"
  end

  test "HTTPS: verifies the cert against the hostname while connected to the IP" do
    %{cert: cert, key: key, cacerts: cacerts} = test_cert(@hostname)
    {port, await} = start_tls_server!(cert, key, cacerts)

    # (a)+(b): connect to 127.0.0.1, but SNI/cert-verify/Host all use the hostname.
    assert {:ok, %{status: 200}} =
             Req.request(
               url: "https://127.0.0.1:#{port}/webhook",
               method: :post,
               body: "x",
               connect_options: [hostname: @hostname, transport_opts: [cacerts: cacerts]],
               retry: false,
               redirect: false
             )

    assert host_only(await.()) == @hostname
  end

  test "HTTPS: without the hostname override, verification fails against the bare IP" do
    # Proves the success above is real: the cert's SAN is the hostname only, so
    # verifying against the connected IP (no override) must be rejected. The failed
    # handshake logs a TLS alert — expected, so capture it.
    %{cert: cert, key: key, cacerts: cacerts} = test_cert(@hostname)
    {port, _await} = start_tls_server!(cert, key, cacerts)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} =
               Req.request(
                 url: "https://127.0.0.1:#{port}/webhook",
                 method: :post,
                 body: "x",
                 connect_options: [transport_opts: [cacerts: cacerts]],
                 retry: false,
                 redirect: false
               )
    end)
  end

  # ── Loopback servers (one request, then close) ──────────────────────────────

  defp start_tcp_server! do
    test = self()
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn(fn ->
      with {:ok, sock} <- :gen_tcp.accept(lsock, 5000) do
        send(test, {:captured, read_request(:gen_tcp, sock)})
        :gen_tcp.send(sock, http_200())
        :gen_tcp.close(sock)
      end

      :gen_tcp.close(lsock)
    end)

    {port, fn -> await_request() end}
  end

  defp start_tls_server!(cert, key, cacerts) do
    test = self()

    {:ok, lsock} =
      :ssl.listen(0,
        mode: :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        certs_keys: [%{cert: cert, key: key}],
        cacerts: cacerts
      )

    {:ok, {_ip, port}} = :ssl.sockname(lsock)

    spawn(fn ->
      with {:ok, tsock} <- :ssl.transport_accept(lsock, 5000),
           {:ok, sock} <- :ssl.handshake(tsock, 5000) do
        send(test, {:captured, read_request(:ssl, sock)})
        :ssl.send(sock, http_200())
        :ssl.close(sock)
      end

      :ssl.close(lsock)
    end)

    {port, fn -> await_request() end}
  end

  defp await_request do
    receive do
      {:captured, raw} -> raw
    after
      5000 -> flunk("loopback server received no request")
    end
  end

  defp read_request(mod, sock, acc \\ "") do
    case mod.recv(sock, 0, 5000) do
      {:ok, data} ->
        acc = acc <> data
        if String.contains?(acc, "\r\n\r\n"), do: acc, else: read_request(mod, sock, acc)

      {:error, _} ->
        acc
    end
  end

  defp http_200, do: "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"

  # The `Host` header value with any `:port` suffix stripped.
  defp host_only(raw) do
    raw
    |> String.split("\r\n")
    |> Enum.find_value(&host_value/1)
  end

  defp host_value(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> if String.downcase(name) == "host", do: strip_port(String.trim(value))
      _ -> nil
    end
  end

  defp strip_port(host), do: host |> String.split(":") |> hd()

  # A CA + leaf cert whose only SAN is `hostname` (no IP), via OTP's test generator.
  defp test_cert(hostname) do
    data =
      :public_key.pkix_test_data(%{
        root: [digest: :sha256, key: {:rsa, 2048, 65_537}],
        peer: [
          digest: :sha256,
          key: {:rsa, 2048, 65_537},
          extensions: [
            {:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(hostname)]}
          ]
        ]
      })

    %{cert: data[:cert], key: data[:key], cacerts: data[:cacerts]}
  end
end
