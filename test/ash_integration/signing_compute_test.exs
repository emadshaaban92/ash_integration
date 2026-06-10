defmodule AshIntegration.Transport.SigningComputeTest do
  use ExUnit.Case, async: true

  alias AshIntegration.Transport.Signing

  @secret "sk_test_secret_key_12345"

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        method: "POST",
        url: "https://api.example.com/api/v1/orders",
        path: "/api/v1/orders",
        host: "api.example.com",
        headers: %{},
        body: ~s({"externalId":"ORD-1"}),
        data: %{"externalId" => "ORD-1"},
        now: %{
          unix_seconds: 1_700_000_000,
          unix_millis: 1_700_000_000_000,
          iso8601: "2023-11-14T22:13:20.000Z",
          rfc1123: "Tue, 14 Nov 2023 22:13:20 GMT"
        }
      },
      overrides
    )
  end

  defp custom(source, overrides \\ %{}) do
    {:custom,
     Map.merge(
       %{secret: @secret, source: source, runtime: :lua, algorithm: :sha256, encoding: :hex},
       overrides
     )}
  end

  defp hmac_hex(secret, data),
    do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)

  describe "compute/2 :none" do
    test "emits no headers and keeps body/url" do
      assert {:ok, %{headers: [], body: :keep, url: :keep}} = Signing.compute(:none, ctx())
    end
  end

  describe "compute/2 {:stripe, _}" do
    test "signs <ts>.<body> as t=,v1= under the configured header" do
      c = ctx()

      {:ok, applied} =
        Signing.compute({:stripe, %{secret: @secret, header_name: "stripe-signature"}}, c)

      expected = hmac_hex(@secret, "#{c.now.unix_seconds}.#{c.body}")
      assert applied.headers == [{"stripe-signature", "t=#{c.now.unix_seconds},v1=#{expected}"}]
      assert applied.body == :keep
    end

    test "lowercases the header name on the wire" do
      {:ok, applied} =
        Signing.compute({:stripe, %{secret: @secret, header_name: "Stripe-Signature"}}, ctx())

      assert [{"stripe-signature", _}] = applied.headers
    end
  end

  describe "compute/2 {:custom, _} — defaults" do
    test "no callbacks → default string_to_sign in an x-signature header" do
      c = ctx()
      {:ok, applied} = Signing.compute(custom(""), c)

      expected = hmac_hex(@secret, "#{c.now.unix_seconds}.#{c.body}")
      assert applied.headers == [{"x-signature", expected}]
      assert applied.body == :keep
    end
  end

  describe "compute/2 {:custom, _} — Model 1 canonical request (Acumatica-style)" do
    @acumatica """
    function string_to_sign(ctx)
      return ctx.method .. "\\n" .. ctx.path .. "\\n" .. ctx.now.iso8601 .. "\\n" .. ctx.digest
    end

    function headers(ctx)
      return { ["x-signature"] = ctx.signature, ["x-timestamp"] = ctx.now.iso8601 }
    end
    """

    test "hashes the body, signs the canonical string, places sig + timestamp headers" do
      c = ctx()
      {:ok, applied} = Signing.compute(custom(@acumatica), c)

      body_digest = :crypto.hash(:sha256, c.body) |> Base.encode16(case: :lower)
      sts = "#{c.method}\n#{c.path}\n#{c.now.iso8601}\n#{body_digest}"
      expected = hmac_hex(@secret, sts)

      headers = Map.new(applied.headers)
      assert headers["x-signature"] == expected
      assert headers["x-timestamp"] == c.now.iso8601
      assert applied.body == :keep
    end
  end

  describe "compute/2 {:custom, _} — algorithm/encoding" do
    test "HMAC-SHA1 + base64 (Twilio-shaped)" do
      c = ctx()
      {:ok, applied} = Signing.compute(custom("", %{algorithm: :sha1, encoding: :base64}), c)

      expected =
        :crypto.mac(:hmac, :sha, @secret, "#{c.now.unix_seconds}.#{c.body}") |> Base.encode64()

      assert applied.headers == [{"x-signature", expected}]
    end
  end

  describe "compute/2 {:custom, _} — Model 2 body placement" do
    @embedded """
    function string_to_sign(ctx)
      return ctx.data.externalId
    end

    function body(ctx)
      return { externalId = ctx.data.externalId, hash = ctx.signature }
    end
    """

    test "injects the signature into the re-encoded body; no default header" do
      c = ctx()
      {:ok, applied} = Signing.compute(custom(@embedded), c)

      expected = hmac_hex(@secret, "ORD-1")
      assert applied.headers == []
      assert is_binary(applied.body)
      assert Jason.decode!(applied.body) == %{"externalId" => "ORD-1", "hash" => expected}
    end
  end

  describe "compute/2 {:custom, _} — failures" do
    test "a non-string string_to_sign return is a classified error" do
      assert {:error, message} =
               Signing.compute(custom("function string_to_sign(ctx) return 123 end"), ctx())

      assert message =~ "string_to_sign"
    end

    test "a raising callback is a classified error" do
      assert {:error, _message} =
               Signing.compute(custom(~S|function string_to_sign(ctx) error("boom") end|), ctx())
    end

    test "a body callback returning an unencodable value is classified, not raised" do
      # string.char(255) is an invalid-UTF-8 byte → Jason can't encode it. It must
      # come back as {:error, _}, never escape as a Jason.EncodeError.
      src = ~S|function body(ctx) return { x = string.char(255) } end|
      assert {:error, message} = Signing.compute(custom(src), ctx())
      assert message =~ "unencodable"
    end
  end

  describe "compute/2 {:custom, _} — placement trust boundary" do
    test "number and boolean header values coerce to strings" do
      src = ~S|function headers(ctx) return { ["x-count"] = 3, ["x-flag"] = true } end|
      {:ok, applied} = Signing.compute(custom(src), ctx())

      headers = Map.new(applied.headers)
      assert headers["x-count"] == "3"
      assert headers["x-flag"] == "true"
    end

    test "a control character in a header value is a classified error" do
      src = ~S|function headers(ctx) return { ["x-sig"] = "a\r\nx-evil: 1" } end|
      assert {:error, message} = Signing.compute(custom(src), ctx())
      assert message =~ "control character"
    end

    test "a control character in a header name is a classified error" do
      src = ~S|function headers(ctx) return { ["x-sig\r\nx-evil"] = "v" } end|
      assert {:error, message} = Signing.compute(custom(src), ctx())
      assert message =~ "control character"
    end

    test "a non-scalar header value is a classified error" do
      src = ~S|function headers(ctx) return { ["x-sig"] = { nested = true } } end|
      assert {:error, message} = Signing.compute(custom(src), ctx())
      assert message =~ "must be a string"
    end

    test "a control character in a url result is a classified error" do
      src = ~S|function url(ctx) return "https://api.example.com/x\r\nHost: evil" end|
      assert {:error, message} = Signing.compute(custom(src), ctx())
      assert message =~ "control character"
    end
  end

  describe "compute/2 {:custom, _} — one compiled session" do
    test "the source's top-level (compiled once) is visible to every callback" do
      # A top-level upvalue captured by both callbacks proves the source compiles
      # and the callbacks run against that one compilation rather than being
      # re-parsed per call. Callbacks stay pure functions of ctx (the session
      # reuses the compiled state immutably; it does not thread callback globals).
      src = """
      local TAG = "v2"
      function string_to_sign(ctx) return TAG .. ":" .. ctx.body end
      function headers(ctx) return { ["x-tag"] = TAG } end
      """

      {:ok, applied} = Signing.compute(custom(src), ctx(%{body: "B"}))
      assert Map.new(applied.headers)["x-tag"] == "v2"
      assert [{"x-tag", "v2"}] = applied.headers
    end
  end

  describe "run/2 dispatch" do
    test ":none union → no signing headers" do
      union = %Ash.Union{type: :none, value: %AshIntegration.Transport.Signing.None{}}
      assert {:ok, %{headers: []}} = Signing.run(union, ctx())
    end
  end
end
