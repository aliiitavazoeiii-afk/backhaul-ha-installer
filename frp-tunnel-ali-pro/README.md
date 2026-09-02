# FRP Tunnel — Ali Pro

Current version: **1.0.1**

Reverse FRP tunnel profile for Iran↔Foreign paths, designed for stable user traffic and one-way reachability cases where Foreign can initiate outbound connections to Iran even if Iran cannot directly reach the Foreign IP.

## Architecture

```text
Users
  ↓
Iran public :443
  ↓
FRPS TCP proxy
  ↑
4 independent FRPC shards over WSS/TLS
  ↑
nginx :8443 → FRPS 127.0.0.1:18443
  ↑
Foreign server
  ↓
existing local Xray/3x-ui 127.0.0.1:443
```

## Stability / security baseline

- FRP v0.71.0 pinned and checksum-verified.
- nginx terminates trusted Let's Encrypt TLS.
- FRPS control backend is loopback-only.
- Foreign validates the Iran TLS certificate using the system CA store.
- `transport.tcpMux = false` so unrelated users are not multiplexed through one yamux TCP carrier.
- Four independent FRPC shards, each with pool 6 (total idle reserve 24).
- One shard restarting does not restart the other shards.
- All shards share one FRP load-balancer group/key for the Iran public port.
- nginx `worker_connections` raised to 65535 and NOFILE raised to avoid the previously observed capacity exhaustion.
- WebSocket proxy buffering disabled; long-lived read/send timeouts enabled.
- `/~!frp` only proxies requests carrying a WebSocket Upgrade header; ordinary probes receive a normal 404.
- Port 80 remains only for ACME renewal.
- FRP token, pair code and load-balancer key are generated locally and stored mode 0600; no runtime secrets are committed.
- Installer does not edit, restart or synchronize Xray/3x-ui.

## Install

### Iran

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/frp-tunnel-ali-pro-v1/frp-tunnel-ali-pro/install.sh) iran
```

The Iran installer prints a secret pair code when ready.

### Foreign

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/frp-tunnel-ali-pro-v1/frp-tunnel-ali-pro/install.sh) foreign
```

Paste the pair code from Iran and select the existing local Xray inbound port (default 443).

## Health

```bash
frp-ali-health
```

## Diagnostics

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/frp-tunnel-ali-pro-v1/frp-tunnel-ali-pro/diagnostics.sh)
```

## Requirements

- Ubuntu/Debian.
- DNS-only/direct A record for the tunnel domain pointing to Iran.
- TCP/80 reachable on Iran for Let's Encrypt issuance/renewal.
- Control port (default 8443) reachable from Foreign to Iran.
- Public user port (default 443) reachable by users on Iran.
- Existing Xray/3x-ui inbound listening on Foreign loopback (normally 127.0.0.1:443).

No tunnel can guarantee zero packet loss, zero latency variation or permanent censorship resistance. Ali Pro is configured to remove the failure modes we directly observed in the earlier deployment while preserving a conventional TLS/WSS transport.
