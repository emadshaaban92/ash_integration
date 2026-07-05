# Kafka Transport

The Kafka transport publishes JSON payloads as Kafka messages, partitioned by event key for ordering guarantees.

## Prerequisites

The Kafka transport requires the `:brod` dependency. Add it to your `mix.exs`:

```elixir
{:brod, "~> 4.0"}
```

The transport will appear in the dashboard automatically once `:brod` is available.

## Configuration

A connection holds the **brokers, security, acks, and a default topic** — the shared cluster connection. Each subscription under it may **override the topic**. Set the connection's `transport_config.type` to `:kafka`:

```elixir
%{
  type: :kafka,
  brokers: ["kafka1:9092", "kafka2:9092"],   # At least one broker required
  topic: "integration-events",                # Default topic (subscriptions may override)
  acks: :all,                                 # :all (default), :leader, or :none
  security: %{type: "none"},                  # See Security below
  headers: %{                                 # Optional custom Kafka headers
    "x-source" => "my-app"
  },
  signing: %{type: "none"}                    # Explicit signing scheme — see Payload Signing
}
```

`acks` controls the producer's required acknowledgements: `:all` waits for all
in-sync replicas (safest), `:leader` waits for the partition leader only, and
`:none` is fire-and-forget.

The topic a delivery uses is the **subscription's topic if set, otherwise the
connection's default** — so several event types can share one connection (one
ordering domain) while still routing to different topics. At least one of the two
must resolve to a topic. The override lives in the subscription's `route_config`
(a transport-tagged union mirroring the connection's `transport_config`):

```elixir
route_config: %{type: :kafka, topic: "orders"}
```

## Security

The `security` field (inside `transport_config`) supports four modes:

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

### Certificate verification (TLS and SASL + TLS)

**Certificate verification is on by default.** Any `:tls` or `:sasl_tls`
connection verifies the broker's certificate chain **and** hostname against the
OS trust store before sending. This is the secure default — no configuration
needed.

The `:tls` and `:sasl_tls` variants accept three verification fields:

| Field         | Default        | Purpose                                                        |
| ------------- | -------------- | ------------------------------------------------------------- |
| `verify`      | `:verify_peer` | `:verify_peer` checks chain + hostname; `:verify_none` disables checking |
| `cacert_pem`  | `nil`          | Inline PEM certificate for a private CA; **augments** the OS trust store when set |
| `sni`         | `nil`          | Server-name override for the handshake (broker fronts a different cert CN) |

**Opting a specific internal connection out.** An internal/firewalled broker
with a self-signed or absent certificate can turn verification off — but only
for that one connection, as a stored, visible choice:

```elixir
security: %{type: "tls", verify: :verify_none}
```

`:verify_none` disables both chain and hostname checks for this connection only.
There is no global switch that disables verification everywhere; the opt-out
lives on the connection so its blast radius is that single endpoint.

> **Hostname check.** Because the default verifies the hostname, a broker reached
> by IP address, or by a name not listed in the certificate's SAN, fails the
> handshake. This is inherent to real verification — fix it at the source (issue
> the cert with the right SANs), override the presented name with `sni`, or, for
> a broker that genuinely can't present a matching cert, opt that one connection
> out with `verify: :verify_none`.

**Trusting a private CA.** When the broker's certificate is signed by an
internal CA (rather than a public one in the OS trust store), keep verification
on and paste the CA's PEM certificate directly onto the connection via
`cacert_pem`. It is stored on the connection record itself — no side-channel
file to place on every node — and **augments** the OS trust store, so the same
connection can still reach public-CA endpoints:

```elixir
security: %{type: "sasl_tls",
            mechanism: :scram_sha_256, username: "user", password: "secret",
            cacert_pem: "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
            sni: "broker.internal"}
```

A `cacert_pem` that contains no decodable certificate is rejected at delivery as
a non-retryable transport error rather than silently trusting nothing.

## Partitioning

Messages are partitioned by the event's **event key** using `:erlang.phash2/2`.
This ensures all events sharing a key go to the same partition, preserving their
order — the same key the pipeline uses for ordering and latest-state coalescing.

## Payload Signing

The connection's `transport_config.signing` union selects the scheme explicitly —
`none` (default, unsigned), `stripe`, or `custom` — exactly as on HTTP. See
[HTTP Transport — Payload Signing](http-transport.md#payload-signing) for the
schemes, verification details, and the `custom` callback model. On Kafka the
signature lands in a **record header** (for `stripe`, the configured
`header_name`); the signing `ctx` carries `topic`/`key`/`headers`/`body`/`data`
instead of URL fields, and a `url` placement callback is rejected as a config
error (Kafka has no URL). As on HTTP, the signature is computed **live at
delivery** over the encoded `defaults.value` with a frozen send-time timestamp
(never stored; recomputed per attempt), so rotating the secret takes effect
immediately without reprocessing.

## Message Format

Each Kafka message is the resolved `defaults` for the route, replayed verbatim:

- **Key**: `defaults.key` (defaults to the event key; used for partitioning)
- **Value**: JSON-encoded `defaults.value` (defaults to `event.data`). An empty value — `nil`, or an empty Lua table (`{}`/`[]` are indistinguishable in Lua) — is produced as an **empty record value** (`<<>>`), not `"{}"`. You therefore can't emit a literal empty JSON object/array as the value; wrap it in a field if a consumer requires one.
- **Timestamp**: the native record timestamp (`ts`, epoch ms) — `defaults.timestamp`, defaulting to the event's `created_at` so the record carries **event time**, not produce time. (If the topic is configured `message.timestamp.type=LogAppendTime`, the broker overrides it.)
- **Headers** (bare, un-prefixed — leading with the event type):
  - `event-id` — the event's UUIDv7 (use it to deduplicate)
  - `event-type` — the event type, e.g. `product.created`
  - `event-version` — the schema version
  - `created-at` — ISO8601 timestamp of the event (also carried natively as the record timestamp above)
  - `event-key` — the ordering/coalescing key
  - `connection-id` — the connection's id
  - `content-type` — `application/json`
  - `signature` — HMAC signature (if a signing secret is set)
  - Any custom headers from config (lowest priority — cannot shadow the above)

All header values, the topic/key, and the timestamp pre-seed the transform's `defaults`, so a subscription can override or remove any of them.

## Connection Management

Kafka clients are managed by `AshIntegration.Transport.KafkaClientManager`:

- One [brod](https://hex.pm/packages/brod) client per active connection
- Clients are started on first delivery
- Producers are started automatically per topic (`auto_start_producers`), so additional subscriptions/topics on the same connection get a producer without a restart
- A change to the effective connection config (brokers, TLS/SASL credentials, acks) restarts the client so the new config takes effect
- Idle clients are automatically torn down after 5 minutes (configurable via `:kafka_idle_timeout_ms`)

## Retry Behavior

Transient broker/connection errors trigger retries:

- `:leader_not_available`
- `:not_leader_for_partition`
- `:preferred_leader_not_available`
- `:broker_not_available`
- `:replica_not_available`
- `:coordinator_not_available`
- `:not_coordinator`
- `:not_enough_replicas`
- `:not_enough_replicas_after_append`
- `:request_timed_out`
- `:timeout`
- `:network_exception`
- `{:connect_error, _}`

All other errors (authorization, invalid topic, etc.) are not retried.

Because the broker accepts bytes without semantic validation, Kafka failures are
classified as **transport** failures: persistent failures count against the
**connection** and can auto-suspend it (pausing all its subscriptions), rather
than suspending a single subscription. A successful publish resets the counter.
