# gRPC Transport *(Experimental)*

> **Status: Experimental** — The gRPC transport is functional and available for use, but
> it is not yet at the same maturity level as the HTTP and Kafka transports. Its public
> interface, configuration options, and operational characteristics may change in future
> releases without a deprecation period.
>
> **Why experimental?** Most Elixir gRPC libraries assume proto definitions are available
> at compile time, but AshIntegration accepts them at runtime (user-provided per
> integration). This requires shelling out to `grpcurl` for each delivery rather than
> using a native Elixir gRPC client with persistent connections. The approach works
> correctly but has inherent trade-offs: per-call process spawn overhead, no connection
> reuse, and string-based error classification. These are acceptable for moderate volume
> but differ from the native client implementations used by HTTP (Req) and Kafka (brod).
>
> If you need gRPC delivery today, this transport will get the job done. Just be aware
> that it is a tier behind HTTP and Kafka in terms of operational maturity.

The gRPC transport delivers events as unary RPC calls using [grpcurl](https://github.com/fullstorydev/grpcurl).

## Prerequisites

The gRPC transport requires **all three** of the following to be available. If any are
missing, the transport will not appear in the dashboard and cannot be used for delivery:

1. **`:protobuf` dependency** — add `{:protobuf, "~> 0.13"}` to your `mix.exs`
2. **`grpcurl`** — CLI tool for making gRPC calls
3. **`protoc`** — Protocol Buffer compiler v3+, used for proto field validation

```bash
# grpcurl (required)
# https://github.com/fullstorydev/grpcurl/releases
curl -LO https://github.com/fullstorydev/grpcurl/releases/download/v<VERSION>/grpcurl_<VERSION>_linux_x86_64.tar.gz \
  && tar -xzf grpcurl_<VERSION>_linux_x86_64.tar.gz -C /usr/local/bin

# protoc (optional, for field-level validation in the test panel)
# https://github.com/protocolbuffers/protobuf/releases
curl -LO https://github.com/protocolbuffers/protobuf/releases/download/v<VERSION>/protoc-<VERSION>-linux-x86_64.zip \
  && unzip protoc-<VERSION>-linux-x86_64.zip -d /usr/local
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

Proto definitions are passed to `grpcurl` which handles parsing and encoding. Google well-known types (`Timestamp`, `Struct`, etc.) may be imported. Field names in the Lua transform output must match the proto field names.

The Lua transform output is JSON-encoded and sent to `grpcurl`, which handles protobuf encoding against the proto's input message type.

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

## How It Works

Each delivery spawns a `grpcurl` process that:

1. Writes the proto definition to a temporary file
2. JSON-encodes the Lua transform output
3. Calls `grpcurl` with the proto file, JSON payload, headers, and security flags
4. Parses the exit code and output for success/failure classification
5. Cleans up temporary files

There are no persistent connections — each delivery is an independent call. This trades a small amount of connection setup latency (~50ms) for correct HTTP/2 handling (flow control, GOAWAY, compression) and zero connection lifecycle management.

## gRPC Status Mapping

gRPC status codes are mapped to HTTP equivalents for retry decisions:

| gRPC Status | Code | HTTP Equiv | Retryable? |
|-------------|------|------------|------------|
| OK | 0 | 200 | N/A |
| INVALID_ARGUMENT | 3 | 400 | No |
| DEADLINE_EXCEEDED | 4 | 504 | Yes |
| NOT_FOUND | 5 | 404 | No |
| PERMISSION_DENIED | 7 | 403 | No |
| RESOURCE_EXHAUSTED | 8 | 429 | Yes |
| UNIMPLEMENTED | 12 | 501 | No |
| UNAVAILABLE | 14 | 503 | Yes |
| UNAUTHENTICATED | 16 | 401 | No |
| Other | * | 500 | Yes |

## Proto Validation

The library includes `AshIntegration.Transports.Grpc.ProtoValidator` which validates a Lua transform output against the proto definition. It reports:

- **Errors**: Type mismatches that will fail at encoding (e.g., string where int32 is expected)
- **Warnings**: Missing fields (will use proto3 defaults) and extra fields (will be dropped)

This is used by the dashboard's test panel to show validation results when previewing gRPC integrations.
