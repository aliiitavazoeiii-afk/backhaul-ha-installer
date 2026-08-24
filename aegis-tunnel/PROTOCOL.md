# AegisMux v1 protocol

All multi-byte integers use network byte order.

## Carrier authentication

Before AegisMux frames are accepted, the WSS carrier must satisfy:

1. TLS server certificate verification (unless explicitly disabled for a lab)
2. RFC6455 HTTP Upgrade
3. `Authorization: Bearer <slot-token>`
4. URL path beginning with the configured high-entropy slot prefix

The first binary WebSocket message must be an Aegis `HELLO` frame with payload `AEGIS/1`.

## Frame header

| Offset | Size | Meaning |
|---|---:|---|
| 0 | 2 | ASCII `AG` |
| 2 | 1 | protocol version (`1`) |
| 3 | 1 | frame type |
| 4 | 4 | stream id |
| 8 | 2 | target id |
| 10 | 2 | payload length |
| 12 | N | payload |

Maximum payload is 32768 bytes.

## Stream lifecycle

Iran owns stream-id allocation.

1. Iran accepts a local TCP connection.
2. Iran chooses a live carrier and sends `OPEN(stream, target_id)`.
3. Foreign maps `target_id` to a locally configured destination and dials it.
4. Both directions send `DATA(stream, bytes)`.
5. EOF/error on either side sends `CLOSE(stream)` and releases local state.

Unknown stream data is ignored; unknown target ids are rejected with `CLOSE`.

## Liveness

Both peers periodically send Aegis `PING` frames and respond with `PONG`. A carrier with no received Aegis frames for three keepalive intervals is closed and recreated. Losing one carrier closes only streams owned by that carrier; the remaining pool stays available for new connections.

## Memory/failure safety

Each stream has a bounded inbound write queue. Queue saturation closes that stream instead of allowing unbounded memory growth or blocking the carrier read loop indefinitely. Socket writes use finite deadlines.

## Versioning

A new incompatible framing design increments the header version and HELLO version. A peer never silently downgrades to another protocol.
