defmodule AshIntegration.Transport.OAuth2Test do
  @moduledoc """
  Unit tests for the shared OAuth2 client-credentials token provider: the grant
  request shape, token caching / refresh-skew behaviour, single-flight under
  concurrency, and failure classification. The token endpoint is stubbed with
  `Req.Test`; descriptors are plain maps (the field access the provider needs),
  so these run without AshCloak — the encrypted round-trip is covered in the
  example app where a real vault is configured.
  """
  # async: false — the SSRF egress policy and the token cache are global; this
  # module mutates the egress config and shares the singleton cache.
  use ExUnit.Case, async: false

  alias AshIntegration.Transport.OAuth2
  alias AshIntegration.Transport.OAuth2.TokenCache

  @stub AshIntegration.Transport.OAuth2

  setup do
    # The token endpoint host is fictitious, so the SSRF gate would otherwise block
    # the fetch before Req.Test sees it. Turn blocking off for this module and
    # point the provider's Req options at the stub.
    prev_egress = Application.get_env(:ash_integration, :egress)
    prev_req = Application.get_env(:ash_integration, :oauth2_req_options)

    Application.put_env(:ash_integration, :egress, block_private?: false)
    Application.put_env(:ash_integration, :oauth2_req_options, plug: {Req.Test, @stub})

    TokenCache.flush()

    on_exit(fn ->
      restore(:egress, prev_egress)
      restore(:oauth2_req_options, prev_req)
      TokenCache.flush()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ash_integration, key)
  defp restore(key, value), do: Application.put_env(:ash_integration, key, value)

  defp descriptor(overrides \\ %{}) do
    Map.merge(
      %{
        token_url: "https://login.test/oauth2/token",
        client_id: "client-#{System.unique_integer([:positive])}",
        client_secret: "s3cr3t-#{System.unique_integer([:positive])}",
        scopes: nil,
        audience: nil,
        extra_params: %{},
        auth_style: :post
      },
      overrides
    )
  end

  defp stub_token(fun), do: Req.Test.stub(@stub, fun)

  defp token_response(conn, extra \\ %{}) do
    Req.Test.json(conn, Map.merge(%{"access_token" => "tok-123", "expires_in" => 3600}, extra))
  end

  defp form_params(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    URI.decode_query(body)
  end

  describe "grant request shape" do
    test "posts a client_credentials grant with the credentials in the body (post style)" do
      test_pid = self()

      stub_token(fn conn ->
        send(test_pid, {:form, form_params(conn), conn.req_headers})
        token_response(conn)
      end)

      d = descriptor(%{client_id: "abc", client_secret: "shh", scopes: "read write"})
      assert {:ok, "tok-123"} = OAuth2.get_token(d)

      assert_received {:form, form, headers}
      assert form["grant_type"] == "client_credentials"
      assert form["client_id"] == "abc"
      assert form["client_secret"] == "shh"
      assert form["scope"] == "read write"
      # post style carries no Basic auth header
      refute Enum.any?(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
    end

    test "basic auth style sends credentials in an Authorization header, not the body" do
      test_pid = self()

      stub_token(fn conn ->
        send(test_pid, {:form, form_params(conn), conn.req_headers})
        token_response(conn)
      end)

      d = descriptor(%{client_id: "id", client_secret: "sec", auth_style: :basic})
      assert {:ok, "tok-123"} = OAuth2.get_token(d)

      assert_received {:form, form, headers}
      assert form["grant_type"] == "client_credentials"
      refute Map.has_key?(form, "client_secret")

      expected = "Basic " <> Base.encode64("id:sec")

      assert Enum.any?(headers, fn {k, v} ->
               String.downcase(k) == "authorization" and v == expected
             end)
    end

    test "basic auth form-urlencodes the credentials before Base64 (RFC 6749 §2.3.1)" do
      test_pid = self()

      stub_token(fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        token_response(conn)
      end)

      # A client id/secret carrying ':' and '%' must be form-urlencoded before being
      # joined and Base64'd, or the ':' would corrupt the userinfo split and '%' would
      # be read as a stray percent-escape by a strict IdP.
      d = descriptor(%{client_id: "id:1", client_secret: "s3:cr%t", auth_style: :basic})
      assert {:ok, _} = OAuth2.get_token(d)

      assert_received {:headers, headers}
      expected = "Basic " <> Base.encode64("id%3A1:s3%3Acr%25t")

      assert Enum.any?(headers, fn {k, v} ->
               String.downcase(k) == "authorization" and v == expected
             end)
    end

    test "drops reserved token params an operator smuggled into extra_params" do
      test_pid = self()

      stub_token(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw, raw})
        token_response(conn)
      end)

      # `grant_type`/`scope` are owned by the grant. If extra_params could inject them
      # the body would carry the param twice (undefined server behaviour); they must be
      # dropped while a genuine extra param (`resource`) still passes through.
      d =
        descriptor(%{
          scopes: "read",
          extra_params: %{"grant_type" => "password", "scope" => "evil", "resource" => "r1"}
        })

      assert {:ok, _} = OAuth2.get_token(d)

      assert_received {:raw, raw}
      params = URI.decode_query(raw)
      assert params["grant_type"] == "client_credentials"
      assert params["scope"] == "read"
      assert params["resource"] == "r1"
      # The smuggled values never reach the wire (no duplicate keys).
      refute raw =~ "password"
      refute raw =~ "evil"
    end

    test "includes audience and arbitrary extra params" do
      test_pid = self()

      stub_token(fn conn ->
        send(test_pid, {:form, form_params(conn)})
        token_response(conn)
      end)

      d = descriptor(%{audience: "https://api.example.com", extra_params: %{"resource" => "r1"}})
      assert {:ok, _} = OAuth2.get_token(d)

      assert_received {:form, form}
      assert form["audience"] == "https://api.example.com"
      assert form["resource"] == "r1"
    end
  end

  describe "caching and refresh skew" do
    test "caches a long-lived token and reuses it across calls" do
      counter = start_counter()

      stub_token(fn conn ->
        bump(counter)
        token_response(conn, %{"expires_in" => 3600})
      end)

      d = descriptor()
      assert {:ok, "tok-123"} = OAuth2.get_token(d)
      assert {:ok, "tok-123"} = OAuth2.get_token(d)

      assert count(counter) == 1
    end

    test "caches a short-lived token briefly instead of refetching every call" do
      counter = start_counter()

      # expires_in (30s) is shorter than the full 60s refresh skew. The skew is
      # capped at HALF the token's lifetime, so the token is still cached briefly
      # (~15s) and reused across rapid deliveries rather than hammering the token
      # endpoint on every send — while still refreshing well before expiry.
      stub_token(fn conn ->
        bump(counter)
        token_response(conn, %{"expires_in" => 30})
      end)

      d = descriptor()
      assert {:ok, _} = OAuth2.get_token(d)
      assert {:ok, _} = OAuth2.get_token(d)

      assert count(counter) == 1
    end

    test "clamps a bogus giant expires_in to the max token TTL" do
      # A buggy/hostile IdP claims the token lives for a century. It must not be
      # pinned that long (it would outlive real revocation and defeat the idle
      # sweeper); the effective TTL is capped at 24h.
      stub_token(fn conn ->
        token_response(conn, %{"expires_in" => 60 * 60 * 24 * 365 * 100})
      end)

      d = descriptor()
      assert {:ok, _} = OAuth2.get_token(d)

      key = OAuth2.cache_key(d)
      assert [{^key, _token, _refresh_at, expires_at}] = :ets.lookup(TokenCache, key)

      max_ttl = :timer.hours(24)
      now = System.monotonic_time(:millisecond)
      # Capped at the ceiling, not the century the server claimed...
      assert expires_at - now <= max_ttl
      # ...but still cached right up to that ceiling (not accidentally clamped short).
      assert expires_at - now > max_ttl - :timer.minutes(1)
    end

    test "a rotated client_secret invalidates the cached token" do
      counter = start_counter()

      stub_token(fn conn ->
        bump(counter)
        token_response(conn)
      end)

      base = descriptor()
      assert {:ok, _} = OAuth2.get_token(base)
      assert {:ok, _} = OAuth2.get_token(base)
      assert count(counter) == 1

      # Same everything but a rotated secret → different cache key → new fetch.
      assert {:ok, _} = OAuth2.get_token(%{base | client_secret: "rotated"})
      assert count(counter) == 2
    end
  end

  describe "single-flight under concurrency" do
    test "N concurrent deliveries coalesce to one token fetch" do
      counter = start_counter()
      test_pid = self()

      # Block the leader's fetch until released, so all callers are in flight at
      # once and single-flight is actually exercised.
      stub_token(fn conn ->
        send(test_pid, :fetch_started)

        receive do
          :release -> :ok
        end

        bump(counter)
        token_response(conn)
      end)

      d = descriptor()

      tasks =
        for _ <- 1..8 do
          Task.async(fn ->
            receive do
              :go -> :ok
            end

            OAuth2.get_token(d)
          end)
        end

      # Allow each task's process to use the test-owned stub, then release them.
      Enum.each(tasks, fn t -> Req.Test.allow(@stub, test_pid, t.pid) end)
      Enum.each(tasks, fn t -> send(t.pid, :go) end)

      # Exactly one fetch starts; no second one races in.
      assert_receive :fetch_started, 1_000
      refute_receive :fetch_started, 200

      Enum.each(tasks, fn t -> send(t.pid, :release) end)

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &match?({:ok, "tok-123"}, &1))
      assert count(counter) == 1
    end
  end

  describe "failure classification" do
    test "a network error is a retryable transport failure" do
      stub_token(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %{failure_class: :transport, retryable: true}} =
               OAuth2.get_token(descriptor())
    end

    test "a 400 invalid_client is a non-retryable transport failure" do
      stub_token(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      assert {:error, %{failure_class: :transport, retryable: false, error_message: msg}} =
               OAuth2.get_token(descriptor())

      assert msg =~ "400"
      assert msg =~ "invalid_client"
    end

    test "a 500 from the token endpoint is retryable" do
      stub_token(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "server_error"})
      end)

      assert {:error, %{failure_class: :transport, retryable: true}} =
               OAuth2.get_token(descriptor())
    end

    test "a 200 without an access_token is a non-retryable protocol error" do
      stub_token(fn conn -> Req.Test.json(conn, %{"token_type" => "bearer"}) end)

      assert {:error, %{failure_class: :transport, retryable: false, error_message: msg}} =
               OAuth2.get_token(descriptor())

      assert msg =~ "access_token"
    end

    test "a blocked token_url (SSRF) fails non-retryably before any request" do
      # Re-enable egress blocking just for this assertion; a loopback token URL
      # must be rejected at fetch, never reaching the endpoint.
      Application.put_env(:ash_integration, :egress, block_private?: true)

      assert {:error, %{failure_class: :transport, retryable: false}} =
               OAuth2.get_token(descriptor(%{token_url: "http://127.0.0.1/token"}))
    after
      Application.put_env(:ash_integration, :egress, block_private?: false)
    end
  end

  describe "token-endpoint SSRF hardening" do
    test "oauth2_req_options cannot re-enable redirect following (the egress pin holds)" do
      # An operator tries to turn redirect following back on for the token endpoint.
      # It must be stripped: the pinned `redirect: false` has to win, or a 3xx from
      # the token URL would re-resolve and bypass the SSRF IP pin.
      Application.put_env(:ash_integration, :oauth2_req_options,
        plug: {Req.Test, @stub},
        redirect: true
      )

      counter = start_counter()

      stub_token(fn conn ->
        bump(counter)

        if count(counter) == 1 do
          # A token endpoint that 302s elsewhere. If redirects were followed, Req
          # would fetch the Location (a second stub call); with the override stripped
          # the 302 is final and surfaces as a non-2xx token-endpoint error.
          conn
          |> Plug.Conn.put_resp_header("location", "https://login.test/oauth2/token2")
          |> Plug.Conn.send_resp(302, "")
        else
          token_response(conn)
        end
      end)

      assert {:error, %{failure_class: :transport}} = OAuth2.get_token(descriptor())
      # The redirect target was never fetched — only the original request was made.
      assert count(counter) == 1
    end
  end

  describe "waiter ref safety (stale single-flight replies)" do
    test "a timed-out waiter is not handed a stale reply on its next wait" do
      # Short waiter timeout so the round-1 waiter gives up while the leader is still
      # blocked mid-fetch — but stays in the leader's waiters list, so the leader's
      # eventual reply lands (stale) in the waiter's long-lived mailbox.
      prev = Application.get_env(:ash_integration, :oauth2_wait_timeout_ms)
      Application.put_env(:ash_integration, :oauth2_wait_timeout_ms, 150)
      on_exit(fn -> restore(:oauth2_wait_timeout_ms, prev) end)

      test_pid = self()
      d = descriptor()
      fetches = start_counter()

      stub_token(fn conn ->
        bump(fetches)
        n = count(fetches)
        send(test_pid, {:fetch_started, n})

        receive do
          {:release, ^n} -> :ok
        end

        if n == 1 do
          # Round-1 leader completes with an ERROR — nothing is cached, so round 2
          # coordinates a fresh fetch instead of hitting the cache.
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "stale_round_1"})
        else
          token_response(conn, %{"access_token" => "fresh-tok"})
        end
      end)

      # ── round 1: leader blocks; the long-lived worker waits, then times out ──
      leader1 = spawn_caller(test_pid, d, :leader1)
      Req.Test.allow(@stub, test_pid, leader1)
      send(leader1, :go)
      assert_receive {:fetch_started, 1}, 1_000

      worker = spawn_worker(test_pid, d)
      send(worker, :go)

      # Times out after ~150ms → retryable transport error, but stays a listed waiter.
      assert_receive {:worker_result, {:error, %{failure_class: :transport, retryable: true}}},
                     2_000

      # Release round-1 leader → it replies to the (no-longer-listening) worker,
      # depositing a STALE reply in the worker's mailbox.
      send(leader1, {:release, 1})
      assert_receive {:leader1_result, {:error, _}}, 2_000

      # ── round 2: a fresh leader blocks; the SAME worker waits again ──
      leader2 = spawn_caller(test_pid, d, :leader2)
      Req.Test.allow(@stub, test_pid, leader2)
      send(leader2, :go)
      assert_receive {:fetch_started, 2}, 1_000

      send(worker, :go)
      assert_receive :worker_round2_started, 1_000
      # Only release the fresh leader once the worker is genuinely blocked awaiting it,
      # so its wait — not a cache hit — is what must ignore the stale reply.
      wait_until_blocked(worker)
      send(leader2, {:release, 2})

      assert_receive {:leader2_result, {:ok, "fresh-tok"}}, 2_000
      # The worker must receive the FRESH token, not the round-1 stale error still
      # sitting in its mailbox (the bug: matching on the shared key grabs the stale one).
      assert_receive {:worker_result, {:ok, "fresh-tok"}}, 2_000
    end

    test "a timed-out waiter is deregistered so the leader's late reply never reaches it" do
      prev = Application.get_env(:ash_integration, :oauth2_wait_timeout_ms)
      Application.put_env(:ash_integration, :oauth2_wait_timeout_ms, 100)
      on_exit(fn -> restore(:oauth2_wait_timeout_ms, prev) end)

      test_pid = self()
      d = descriptor()

      stub_token(fn conn ->
        send(test_pid, :fetch_started)
        receive do: (:release -> :ok)
        token_response(conn)
      end)

      leader = spawn_caller(test_pid, d, :leader)
      Req.Test.allow(@stub, test_pid, leader)
      send(leader, :go)
      assert_receive :fetch_started, 1_000

      # The worker waits, times out (~100ms) and deregisters, then stays alive so we
      # can inspect its mailbox.
      worker =
        spawn(fn ->
          send(test_pid, {:worker_result, OAuth2.get_token(d)})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:worker_result, {:error, %{retryable: true}}}, 2_000

      # The worker has already timed out and cancelled its wait; NOW the leader
      # completes. A correctly-deregistered waiter is sent nothing.
      send(leader, :release)
      assert_receive {:leader_result, {:ok, "tok-123"}}, 2_000

      wait_until_blocked(worker)
      {:messages, messages} = Process.info(worker, :messages)
      refute Enum.any?(messages, &match?({:oauth2_token, _ref, _result}, &1))

      send(worker, :stop)
    end
  end

  # A caller that fetches once when told `:go`, reporting its result tagged with `tag`.
  defp spawn_caller(test_pid, descriptor, tag) do
    result_tag = :"#{tag}_result"

    spawn(fn ->
      receive do: (:go -> :ok)
      send(test_pid, {result_tag, OAuth2.get_token(descriptor)})
    end)
  end

  # The long-lived "Broadway worker": waits on the same key twice (a `:go` before each),
  # signalling before its second fetch so the test can release the leader only once the
  # worker is genuinely blocked.
  defp spawn_worker(test_pid, descriptor) do
    spawn(fn ->
      receive do: (:go -> :ok)
      send(test_pid, {:worker_result, OAuth2.get_token(descriptor)})

      receive do: (:go -> :ok)
      send(test_pid, :worker_round2_started)
      send(test_pid, {:worker_result, OAuth2.get_token(descriptor)})
    end)
  end

  # Block until `pid` is parked in a receive (bounded so a regression can't hang the
  # suite — the final assertions catch the bug regardless).
  defp wait_until_blocked(pid), do: wait_until_blocked(pid, 200)
  defp wait_until_blocked(_pid, 0), do: :ok

  defp wait_until_blocked(pid, tries) do
    case Process.info(pid, :status) do
      {:status, :waiting} -> :ok
      _ -> Process.sleep(5) && wait_until_blocked(pid, tries - 1)
    end
  end

  # ── tiny concurrent counter ────────────────────────────────────────────────
  defp start_counter, do: :counters.new(1, [:atomics])
  defp bump(counter), do: :counters.add(counter, 1, 1)
  defp count(counter), do: :counters.get(counter, 1)
end
