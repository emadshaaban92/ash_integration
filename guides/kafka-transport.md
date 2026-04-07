# Kafka Transport

The Kafka transport publishes JSON payloads as Kafka messages, with per-resource-id partitioning for ordering guarantees.

## Configuration

Set `transport_config.type` to `:kafka`:

```elixir
%{
  type: :kafka,
  brokers: ["kafka1:9092", "kafka2:9092"],   # At least one broker required
  topic: "integration-events",
  headers: %{                                 # Optional custom Kafka headers
    "x-source" => "my-app"
  }
}
```

## Security

The `security` field supports four modes:

### None (default)

```elixir
security: %{type: "none"}
```

### TLS Only

Enables SSL/TLS for the broker connection.

```elixir
security: %{type: "tls"}
```

### SASL

Adds SASL authentication (plaintext connection).

```elixir
security: %{type: "sasl", mechanism: :plain, username: "user", password: "secret"}
```

Supported mechanisms: `:plain`, `:scram_sha_256`, `:scram_sha_512`.

### SASL + TLS

Combines SASL authentication with SSL/TLS.

```elixir
security: %{type: "sasl_tls", mechanism: :scram_sha_256, username: "user", password: "secret"}
```

## Partitioning

Messages are partitioned by `resource_id` using `:erlang.phash2/2`. This ensures all events for the same resource go to the same partition, preserving ordering.

## Payload Signing

When `signing_secret` is set, an `x-payload-signature` Kafka header is added with the same HMAC-SHA256 format used by the HTTP transport. See [HTTP Transport](http-transport.md#payload-signing) for verification details.

## Message Format

Each Kafka message contains:

- **Key**: The `resource_id` (used for partitioning)
- **Value**: JSON-encoded payload (after Lua transform)
- **Headers**:
  - `event_id` — unique event identifier
  - `integration_id` — outbound integration ID
  - `x-payload-signature` — HMAC signature (if signing secret is set)
  - Any custom headers from config

## Connection Management

Kafka connections are managed by `AshIntegration.KafkaClientManager`:

- One [brod](https://hex.pm/packages/brod) client per active integration
- Clients are started on first delivery
- Idle clients are automatically torn down after 5 minutes (configurable via `:kafka_idle_timeout_ms`)

## Retry Behavior

The following Kafka errors trigger retries:

- `:leader_not_available`
- `:not_leader_for_partition`
- `:request_timed_out`
- `:not_enough_replicas`
- `{:connect_error, _}`
- `:timeout`

All other errors (authorization, invalid topic, etc.) are not retried.
