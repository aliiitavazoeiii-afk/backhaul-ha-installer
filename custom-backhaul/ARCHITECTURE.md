# Custom Backhaul v2

This branch develops a private Backhaul-derived transport build without changing the production `main` installer until the custom binary passes build and lab tests.

## Goals

1. Keep the proven Backhaul forwarding core and our HAProxy health/failover architecture.
2. Remove avoidable upstream security weaknesses.
3. Reduce static transport signatures and active-probe oracles.
4. Make deployment-specific wire details configurable rather than globally identical.
5. Preserve observability and automatic failover.

## Threat model

We assume an on-path observer can see IPs, ports, TCP flow metadata, TLS ClientHello/SNI/ALPN, TLS record sizes and timing, and can actively connect to public endpoints. The observer normally cannot read HTTP/WebSocket paths or headers inside a correctly authenticated TLS session.

Therefore changing only WebSocket headers is not enough. The highest-value changes are TLS behavior, public endpoint behavior under active probing, connection/timing patterns, and keeping raw Backhaul transports out of the preferred public path.

## Phase 1: custom binary hardening

The first custom build is based on the exact upstream `v0.7.2` source and applies a deterministic patch during CI.

Changes:

- WSS certificate verification is enabled by default. `tls_skip_verify = true` is an explicit compatibility escape hatch only.
- WSS ClientHello uses a uTLS Chrome profile instead of the stock Go TLS ClientHello.
- Because Gorilla WebSocket performs an HTTP/1.1 Upgrade, the Chrome-like uTLS ClientHello is constrained to ALPN `http/1.1` so the server cannot negotiate h2 and then reject the WebSocket request.
- WebSocket control and tunnel paths become deployment-configurable (`ws_control_path`, `ws_tunnel_path`).
- Unknown or unauthenticated WebSocket paths return a generic 404 instead of exposing a distinctive 401 authentication oracle.
- WebSocket control frames use variable padding while retaining the signal byte as byte 0, preserving compatibility with the existing control parser.
- Server heartbeat timing gets bounded jitter instead of an exact fixed interval.
- User-Agent and Origin are configurable for the WebSocket client. These are primarily active-probe/application-profile controls because they are encrypted inside WSS.

## Phase 2: stealth WSS ingress

Do not expose the Backhaul TLS server directly on the backbone SNI.

Implemented lab topology:

```text
Foreign custom client
  -> TLS/WSS backbone-domain:443
  -> Iran HAProxy TCP/SNI router
  -> nginx TLS/HTTP decoy 127.0.0.1:9443
       / and ordinary paths -> normal static HTTPS behavior
       per-install secret WS paths -> Backhaul WSMux 127.0.0.1:18080
  -> WSMux data ports 10443/10444/10445
  -> Foreign Xray / health / iperf loopback targets
```

The Phase 2 installer is `custom-backhaul/enable-stealth-wss.sh` and has role-aware behavior:

- Iran generates and stores per-install `WSS_CONTROL_PATH` and `WSS_TUNNEL_PATH` values in `/root/backhaul-ha-secrets.env`.
- Iran changes the existing `backhaul-wss` service configuration from direct `wssmux` TLS on `127.0.0.1:8443` to plain `wsmux` on loopback `127.0.0.1:18080`.
- nginx owns the certificate and decoy HTTPS behavior on loopback `127.0.0.1:9443`.
- HAProxy keeps the public `:443` SNI router but sends the backbone SNI to nginx rather than directly to Backhaul.
- Only the generated secret control path and tunnel prefix are proxied to Backhaul; ordinary requests are served as decoy HTTPS/404 behavior.
- Foreign keeps `wssmux` externally, verifies the real certificate, and uses the same generated secret paths.
- Existing TCPMux and plain-TCP paths remain untouched, so they provide failover while the two Phase 2 endpoints are migrated.
- `custom-backhaul/rollback-stealth-wss.sh` restores the pre-Phase-2 Backhaul/HAProxy/client configuration from a first-run backup.

This improves resistance to simple active probing because a client without the deployment-specific path sees an ordinary HTTPS virtual host rather than a directly exposed Backhaul TLS endpoint. It does not make traffic-analysis classification impossible.

## Phase 3: transport diversity

Current TCPMux/plain-TCP fallbacks are useful for availability but remain raw Backhaul-family transports on the wire. For censorship resistance, the long-term secondary path should be independently wrapped rather than merely another raw Backhaul mode.

Planned priority:

1. stealth WSS/WSMux through decoy HTTPS frontend
2. TLS-wrapped TCPMux using a separate SNI/profile
3. IP-restricted plain TCP emergency path

HAProxy continues to select a path only after end-to-end health succeeds.

## Rotation

Each installation should generate its own:

- WSS control path
- WSS tunnel prefix
- transport tokens
- optional decoy hostname/content profile

These values are secrets for active-probe resistance, not substitutes for cryptographic authentication.

## Non-goals

This design cannot guarantee invisibility against a state-level classifier. Traffic-analysis and endpoint/IP reputation can still identify or block a tunnel. The objective is to remove easy shared signatures, improve cryptographic hygiene, make active probing less informative, and provide independent fallback paths.

## Release gate

Nothing from this branch should be promoted to `main` until all of the following pass:

- custom binary compiles from a pinned upstream tag
- `go test ./...`
- WSS certificate verification test
- stock-vs-custom interoperability test where intended
- end-to-end health test
- deliberate WSS/TCP failover test
- Phase 2 decoy root and unknown-path probe test
- Phase 2 secret-path WSS end-to-end health/throughput test
- reboot persistence test
- packet capture comparison of stock vs custom ClientHello and connection timing
