# Custom Backhaul v2

This branch contains the validated lab implementation of the private Backhaul v0.7.2-derived HA transport stack. Production `main` remains unchanged until an explicit promotion decision is made.

## Goals

1. Keep the proven Backhaul forwarding core and HAProxy end-to-end health/failover architecture.
2. Remove avoidable upstream security weaknesses.
3. Reduce static transport signatures and active-probe oracles.
4. Make deployment-specific wire details configurable rather than globally identical.
5. Preserve observability, automatic failover, rollback, and reboot persistence.

## Threat model

We assume an on-path observer can see IPs, ports, TCP flow metadata, TLS ClientHello/SNI/ALPN, TLS record sizes and timing, and can actively connect to public endpoints. The observer normally cannot read HTTP/WebSocket paths or headers inside a correctly authenticated TLS session.

Therefore changing only WebSocket headers is not enough. The highest-value changes are TLS behavior, public endpoint behavior under active probing, connection/timing patterns, and keeping raw Backhaul transports out of the preferred public path.

## Phase 1: custom binary hardening

The custom build is based on the exact upstream `v0.7.2` source and applies a deterministic patch during CI.

Changes:

- WSS certificate verification is enabled by default. `tls_skip_verify = true` is an explicit compatibility escape hatch only.
- WSS ClientHello uses a uTLS Chrome profile instead of the stock Go TLS ClientHello.
- Because Gorilla WebSocket performs an HTTP/1.1 Upgrade, the Chrome-like uTLS ClientHello is constrained to ALPN `http/1.1` so the server cannot negotiate h2 and then reject the WebSocket request.
- WebSocket control and tunnel paths are deployment-configurable (`ws_control_path`, `ws_tunnel_path`).
- Unknown or unauthenticated WebSocket paths return a generic 404 instead of exposing a distinctive 401 authentication oracle.
- WebSocket control frames use variable padding while retaining the signal byte as byte 0, preserving compatibility with the existing control parser.
- Server heartbeat timing gets bounded jitter instead of an exact fixed interval.
- User-Agent and Origin are configurable for the WebSocket client. These are primarily active-probe/application-profile controls because they are encrypted inside WSS.

## Phase 2: decoy WSS ingress with split TLS

The initial Phase 2 implementation used nginx for both TLS termination and HTTP/WebSocket routing. Lab testing found severe one-direction WSS throughput stalls in that topology while TCPMux/plain transports remained fast and CPU was mostly idle.

Controlled A/B testing isolated the problem:

1. `stunnel TLS -> Backhaul WSMux` removed the stalls.
2. `stunnel TLS -> nginx plain HTTP/WebSocket proxy -> Backhaul WSMux` also removed the stalls.
3. Therefore nginx HTTP/WebSocket proxying was retained, while TLS termination moved to stunnel.

Validated final Phase 2 topology:

```text
Foreign custom WSSMux client
  -> bh1.biya2film.top:443
  -> Iran HAProxy TCP/SNI router
  -> stunnel TLS terminator 127.0.0.1:9443
  -> nginx plain HTTP decoy/router 127.0.0.1:9080
       / and ordinary paths -> static decoy HTTP behavior
       per-install secret WS paths -> Backhaul WSMux 127.0.0.1:18080
  -> WSMux data/health/iperf ports 10443/10444/10445
  -> Foreign Xray / health / iperf loopback targets
```

Phase 2 deployment starts with `custom-backhaul/enable-stealth-wss.sh`; the validated split-TLS migration is `custom-backhaul/upgrade-phase2-split-tls.sh`.

- Iran generates and stores per-install `WSS_CONTROL_PATH` and `WSS_TUNNEL_PATH` values in `/root/backhaul-ha-secrets.env`.
- Backhaul WSS server runs as plain `wsmux` on loopback `127.0.0.1:18080`.
- stunnel owns the backbone certificate on loopback `127.0.0.1:9443`.
- nginx owns only plain loopback HTTP on `127.0.0.1:9080` and performs decoy/secret-path routing.
- HAProxy keeps the public `:443` SNI router and sends the backbone SNI to stunnel `:9443`.
- Only generated secret control/tunnel paths are proxied to Backhaul; ordinary requests receive decoy 200/404 behavior.
- Foreign remains `wssmux`, validates the real certificate, and uses the generated secret paths.
- Certificate renewal restarts the WSS stunnel terminator through a deploy hook.
- `custom-backhaul/verify-phase2-split-tls.sh` is authoritative for the final Phase 2 ingress.
- Temporary A/B service `:9445` is removed by `custom-backhaul/cleanup-phase2-ab.sh`.

This improves resistance to simple active probing because a client without the deployment-specific path sees an ordinary HTTPS virtual host rather than a directly exposed Backhaul TLS endpoint. It does not make traffic-analysis classification impossible.

## Phase 3: independently TLS-wrapped TCPMux backup

Phase 3 independently TLS-wraps the TCPMux backup instead of exposing raw Backhaul TCPMux on the network.

Validated topology:

```text
Foreign Backhaul TCPMux
  -> 127.0.0.1:13080
  -> stunnel client
       certificate-chain verification
       hostname verification
       separate SNI/profile
  -> edge1.biya2film.top:443
  -> Iran HAProxy SNI router
  -> stunnel TLS server 127.0.0.1:9444
  -> raw Backhaul TCPMux 127.0.0.1:18081
  -> TCPMux data/health/iperf ports 11443/11444/11445
```

- Phase 3 requires Phase 2 first.
- The TCPMux TLS hostname is separate from the WSS hostname and stored as `TCP_TLS_DOMAIN`.
- HAProxy selects the TCPMux wrapper by SNI on the same public `:443` listener.
- Iran raw TCPMux is loopback-only on `127.0.0.1:18081`.
- Foreign Backhaul TCPMux dials local stunnel `127.0.0.1:13080`.
- Foreign stunnel validates the public CA chain and hostname and sends the secondary SNI.
- Legacy public raw TCPMux `:3080` is removed.
- Plain TCP `:3081` remains IP-restricted as the emergency third path.
- `custom-backhaul/verify-phase3-tcptls.sh` validates the Phase 3 chain and all three end-to-end health paths.

The secondary stunnel/OpenSSL TLS profile is deliberately different from the Phase 1/2 uTLS WebSocket profile. This is transport diversity, not a claim of browser indistinguishability. A TLS-wrapped long-lived TCP tunnel can still be classified from metadata or endpoint behavior.

## Final priority order

1. WSSMux through backbone SNI, stunnel TLS, nginx decoy/path router, and loopback WSMux.
2. Independently TLS-wrapped TCPMux using a separate SNI/profile.
3. IP-restricted plain TCP emergency path.

HAProxy selects a path only after end-to-end HTTP health succeeds.

## Validated lab results — 2026-08-21

Final pair:

- Iran: `185.215.230.204`
- Foreign: `193.57.9.196`
- WSS SNI: `bh1.biya2film.top`
- TCPMux TLS SNI: `edge1.biya2film.top`

Validation completed:

- Custom build and Go tests passed in GitHub Actions during development.
- Phase 2 split-TLS verifier: `23 OK, 0 WARN, 0 FAIL`.
- Phase 3 verifier: `16 OK, 0 WARN, 0 FAIL`.
- Phase-3-aware deep diagnostics passed without failures after the final diagnostics update.
- All three end-to-end health paths returned HTTP 200.
- Legacy direct WSS `:8443` and raw TCPMux `:3080` are not exposed.
- Decoy root returns HTTP 200; random and unauthenticated secret paths return generic HTTP 404.
- Deliberate WSS -> TCPMux -> plain -> TCPMux -> WSS failover/failback was validated before the final split-TLS performance optimization.
- After the split-TLS optimization, all three paths remained healthy.
- Both hosts were rebooted after final deployment; services recovered, diagnostics remained clean, and an actual VPN client remained connected/functional.

Observed throughput samples:

- Final WSS single-stream Iran -> Foreign: `228`, `226`, `231 Mbps` across three consecutive 15-second runs, with the prior multi-second zero-throughput stalls eliminated.
- TLS-wrapped TCPMux deep sample: approximately `308 Mbps` Iran -> Foreign and `234 Mbps` Foreign -> Iran.
- Plain TCP deep sample: approximately `392 Mbps` Iran -> Foreign and `256 Mbps` Foreign -> Iran.

Performance figures are point-in-time lab measurements, not guaranteed capacity.

## Rotation

Each installation should generate or configure its own:

- WSS control path
- WSS tunnel prefix
- transport tokens
- separate TCPMux TLS hostname
- optional decoy hostname/content profile

These values are deployment-specific controls, not substitutes for cryptographic authentication.

## Non-goals

This design cannot guarantee invisibility against a state-level classifier. Traffic-analysis and endpoint/IP reputation can still identify or block a tunnel. The objective is to remove easy shared signatures, improve cryptographic hygiene, make active probing less informative, and provide independent fallback paths.

## Promotion state

The experimental branch is now a validated lab baseline. `main` is intentionally still unchanged.

Before a production promotion, an operator may additionally choose to capture and compare WSS versus TLS-wrapped TCPMux packet traces under representative load. This is useful for transport-profile analysis but is not required for the functional/reboot baseline recorded above.
