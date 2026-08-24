# Aegis Tunnel

Aegis is the independent transport engine for the Dual-Foreign stack. It is not a Backhaul fork and does not speak Backhaul's control, mux, heartbeat, or stream protocol.

## Design goals

- keep the proven Iran -> Foreign A/B Active/Active topology
- remove dependency on any Backhaul wire behavior or control-channel fingerprint
- preserve outbound-only Foreign connectivity
- make the inner multiplexing protocol versioned and owned by this project
- separate the **carrier** (WSS today; other standard carriers later) from **AegisMux**
- fail closed on bad auth/version/framing
- bound per-stream queues to avoid unbounded memory growth
- allow rolling replacement of a Foreign without rotating the other slot
- never require an agent/database on X-UI/Xray itself

## What Aegis does not promise

No transport is "DPI proof". An operator can still block an IP, domain, certificate, a whole protocol family, or all traffic that matches a broader policy. The engineering goal is protocol independence and transport agility, not an impossible guarantee of invisibility.

## AegisMux v1

Each Foreign maintains a small pool of outbound WebSocket carriers to Iran. A local TCP connection accepted on Iran is assigned a stream id and one carrier. The Foreign dials the configured target for the stream and bidirectional data is framed over that carrier.

Current frame types:

- `HELLO`
- `OPEN`
- `DATA`
- `CLOSE`
- `PING`
- `PONG`

Each frame begins with an Aegis magic/version header and carries a 32-bit stream id. `DATA` is capped at 32 KiB per frame. WebSocket writes are serialized, while inbound per-stream writes use bounded queues so one blocked target cannot indefinitely block every stream.

## Carrier v1: WSS

The first carrier is ordinary RFC6455 WebSocket over TLS/HTTP/1.1. Authentication is a per-slot bearer token plus a high-entropy path prefix. Every carrier adds a fresh random path suffix. TLS certificate validation is enabled by default.

The outer carrier is intentionally independent of AegisMux. Future standard carriers can be added behind the same stream API without changing client identities, HAProxy topology, or the panel.

## Current status

`0.1.0` is a canary/reference implementation. It has local parallel-stream integration coverage and race-detector coverage. The validated WSS Stealth stack remains the production fallback until Aegis passes real-server health, failover, soak, and throughput tests.

## Local tests

```bash
go test ./... -race
go vet ./...
go build ./cmd/aegis
```
