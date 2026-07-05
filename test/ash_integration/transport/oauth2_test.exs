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

    test "refetches a token that is already within the refresh skew" do
      counter = start_counter()

      # expires_in (30s) is shorter than the refresh skew (60s), so the token is
      # never considered fresh — every call refetches rather than serving a token
      # about to expire.
      stub_token(fn conn ->
        bump(counter)
        token_response(conn, %{"expires_in" => 30})
      end)

      d = descriptor()
      assert {:ok, _} = OAuth2.get_token(d)
      assert {:ok, _} = OAuth2.get_token(d)

      assert count(counter) == 2
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

  # ── tiny concurrent counter ────────────────────────────────────────────────
  defp start_counter, do: :counters.new(1, [:atomics])
  defp bump(counter), do: :counters.add(counter, 1, 1)
  defp count(counter), do: :counters.get(counter, 1)
end
