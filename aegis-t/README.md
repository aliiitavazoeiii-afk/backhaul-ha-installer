# Aegis-T 1.0

Aegis-T is a reverse TCP/TLS transport designed for networks where UDP/QUIC is unreliable and multiplexing many user streams over a few TCP carriers causes cross-stream head-of-line blocking.

## Core rule

**One active user TCP connection consumes one dedicated carrier TCP connection.**

Foreign keeps a warm pool of authenticated TLS carriers connected to Iran. When a user arrives on Iran, one idle carrier is assigned exclusively to that user. The carrier is never multiplexed or reused for another user. Foreign immediately replenishes the warm pool while the assigned carrier is active.

## Data path

```text
User -> Iran TCP/443 -> HAProxy -> 127.0.0.1:10443
                                      |
                                      | dedicated carrier
                                      v
                              TLS/TCP reverse tunnel
                                      |
                                      v
                             Foreign -> 127.0.0.1:443
                                      |
                                      v
                                     Xray
```

Carrier connections arrive on the same public Iran TCP/443 with a dedicated SNI. HAProxy routes that SNI to Aegis-T on `127.0.0.1:9443`; all other SNI values go to the user gateway.

## Properties

- TCP only; no UDP/QUIC dependency.
- No WebSocket.
- No cross-user multiplexing.
- Natural TCP backpressure; no small per-stream drop queue.
- Valid TLS certificate and ordinary HTTP/1.1 carrier bootstrap.
- HMAC-SHA256 carrier authentication with timestamp, random nonce, and replay rejection.
- Random path suffix and variable encrypted HTTP-header padding per carrier.
- Invalid/unauthorized HTTP probes receive an ordinary 404 response.
- Foreign Xray health gating: when local `127.0.0.1:443` is down, idle carriers are closed and the Iran readiness endpoint falls as the pool drains.
- Iran readiness is exposed on `127.0.0.1:10444` for HAProxy health checks.
- The tunnel never installs or edits 3x-ui/Xray.

## Explicit non-goals

Aegis-T does not claim to be undetectable. No transport can guarantee survival against a censor that blocks its IPs, all TLS to the endpoint, or all relevant traffic classes. The design reduces avoidable protocol fingerprints and removes the multiplexing failure mode seen in the earlier WebSocket carrier design.
