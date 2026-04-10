# HTTP Transport

The HTTP transport delivers JSON payloads to external endpoints via HTTP requests. This is the simplest transport and a good starting point.

## Configuration

When creating an outbound integration, set `transport_config.type` to `:http`:

```elixir
%{
  type: :http,
  url: "https://api.example.com/webhooks",
  method: :post,          # :post (default), :put, :patch, or :delete
  timeout_ms: 30_000,     # Request timeout in milliseconds (default: 30s, min: 1s)
  headers: %{             # Optional custom headers
    "x-source" => "my-app"
  }
}
```

## Authentication

The `auth` field supports four strategies:

### None (default)

```elixir
auth: %{type: "none"}
```

### Bearer Token

Adds an `Authorization: Bearer <token>` header.

```elixir
auth: %{type: "bearer_token", token: "sk-live-abc123"}
```

### API Key

Adds a custom header with the key value.

```elixir
auth: %{type: "api_key", header_name: "X-API-Key", value: "my-api-key"}
```

### Basic Auth

Adds an `Authorization: Basic <base64>` header.

```elixir
auth: %{type: "basic_auth", username: "user", password: "secret"}
```

All auth credentials are encrypted at rest via AshCloak.

## Payload Signing

When `signing_secret` is set, payloads are signed with HMAC-SHA256. The signature is sent in the `x-payload-signature` header:

```
x-payload-signature: t=1234567890,v1=abc123def456...
```

To verify on the receiving end:

1. Extract the timestamp (`t`) and signature (`v1`) from the header
2. Compute `HMAC-SHA256(signing_secret, "#{timestamp}.#{raw_body}")`
3. Compare with `v1` (hex-encoded, lowercase)

## Error Handling

| Response | Behavior |
|----------|----------|
| 2xx | Success — event state → `delivered`, logged as `:success` |
| 5xx | Retried (up to 20 attempts with exponential backoff) |
| 4xx | Not retried, logged as `:failed` |
| Network error | Retried |

After enough consecutive failures across all events for an integration, the integration is **auto-suspended** — delivery stops but events continue accumulating safely until an operator investigates and un-suspends.

## Req Options

You can inject custom options into all HTTP requests (useful for testing):

```elixir
config :ash_integration, :req_options, [plug: {Req.Test, MyApp.WebhookStub}]
```
