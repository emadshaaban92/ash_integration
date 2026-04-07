# gRPC Transport

The gRPC transport delivers events as protobuf-encoded unary RPC calls over HTTP/2.

## Prerequisites

The gRPC transport requires `protoc` (Protocol Buffer compiler v3+) installed on the system PATH. It is used at runtime to parse proto definitions into descriptors.

```bash
# Ubuntu/Debian
apt install protobuf-compiler

# macOS
brew install protobuf
```

## Configuration

Set `transport_config.type` to `:grpc`:

```elixir
%{
  type: :grpc,
  endpoint: "grpc.example.com:443",
  service: "mypackage.MyService",
  method: "ProcessEvent",
  proto_definition: """
  syntax = "proto3";
  package mypackage;

  service MyService {
    rpc ProcessEvent (EventRequest) returns (EventResponse);
  }

  message EventRequest {
    string event_id = 1;
    string action = 2;
    string data_json = 3;
  }

  message EventResponse {
    bool accepted = 1;
  }
  """,
  timeout_ms: 30_000,
  headers: %{}            # Optional custom gRPC metadata
}
```

### Proto Definitions

Proto definitions must be **self-contained** (no `import` statements). All message types must be defined inline. Parsed descriptors are cached in ETS and invalidated when the proto content changes.

The Lua transform script output is dynamically encoded against the proto's input message type. Field names in the transform output must match the proto field names as strings.

## Security

The `security` field supports four modes:

### None (default)

Connects over plaintext HTTP/2 (h2c).

```elixir
security: %{type: "none"}
```

### TLS

Connects over HTTPS with server certificate verification.

```elixir
security: %{type: "tls"}
```

### Bearer Token

Connects over HTTPS and adds an `authorization: Bearer <token>` metadata header.

```elixir
security: %{type: "bearer_token", token: "my-token"}
```

### Mutual TLS

Connects over HTTPS with client certificate authentication.

```elixir
security: %{type: "mutual_tls", client_cert_pem: "...", client_key_pem: "..."}
```

## Payload Signing

When `signing_secret` is set, an `x-payload-signature` gRPC metadata entry is added with the same HMAC-SHA256 format used by the HTTP transport. See [HTTP Transport](http-transport.md#payload-signing) for verification details.

## Connection Management

gRPC connections are managed per-integration:

- Each integration gets its own `Channel` GenServer with a dedicated HTTP/2 connection (via [Mint](https://hex.pm/packages/mint))
- Connections are established on first delivery and reused for subsequent calls
- Idle connections are closed after 5 minutes (configurable via `:grpc_idle_timeout_ms`)
- Connections automatically reconnect if the underlying HTTP/2 connection drops

## gRPC Status Mapping

gRPC status codes are mapped to HTTP equivalents for retry decisions:

| gRPC Status | Code | HTTP Equiv | Retryable? |
|-------------|------|------------|------------|
| OK | 0 | 200 | N/A |
| INVALID_ARGUMENT | 3 | 400 | No |
| DEADLINE_EXCEEDED | 4 | 504 | Yes |
| NOT_FOUND | 5 | 404 | No |
| PERMISSION_DENIED | 7 | 403 | No |
| RESOURCE_EXHAUSTED | 8 | 429 | No |
| UNIMPLEMENTED | 12 | 501 | Yes |
| UNAVAILABLE | 14 | 503 | Yes |
| UNAUTHENTICATED | 16 | 401 | No |
| Other | * | 500 | Yes |

## Proto Validation

The library includes `AshIntegration.Transports.Grpc.ProtoValidator` which validates a Lua transform output against the proto definition before encoding. It reports:

- **Errors**: Type mismatches that will fail at encoding (e.g., string where int32 is expected)
- **Warnings**: Missing fields (will use proto3 defaults) and extra fields (will be dropped)

This is used by the dashboard's test panel to show validation results when previewing gRPC integrations.
