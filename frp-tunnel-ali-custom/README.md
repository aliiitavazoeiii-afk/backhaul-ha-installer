# FRP Tunnel — Ali Tavazoei Custom Version

> **Current track:** v0.2.0-rc1  
> **Status:** release candidate / lab-first. Do not call it production-proven until it survives real user traffic.

A TCP-first reverse tunnel profile designed around the failure modes observed in the earlier Aegis deployment: cross-user head-of-line blocking, small burst-sensitive logical queues, and global failure reactions.

## Architecture

```text
Users
  ↓
Iran public :443
  ↓
FRPS TCP proxy listener
  ↓
one independent WSS/TLS work connection per active user TCP stream
  ↓
FRPC
  ↓
existing Foreign Xray/3x-ui target (normally 127.0.0.1:443)
```

Control/WSS endpoint uses a separate port (default `8443`).

### Why `tcpMux = false`

FRP's normal TCP mux uses yamux and can place unrelated logical streams inside one congestion-controlled TCP connection. On a lossy Iran↔Foreign path, that can create shared head-of-line stalls.

This project disables FRP TCP mux on both sides. In FRP v0.71.0, a connection request then goes through a real transport dial rather than opening a yamux stream. `poolCount` is therefore used as a reserve of already-established independent work connections.

## v2 security / DPI baseline

- WSS + TLS.
- A real, publicly trusted certificate is mandatory on Iran.
- Foreign verifies the server certificate against the system CA store.
- FRP custom TLS first byte disabled.
- No plaintext FRP magic before TLS.
- Token authentication for login, heartbeat and new work connections.
- Token stored in a mode-0600 file, not inline TOML.
- Valid normal TLS/HTTP-WebSocket behavior; no malformed packet tricks.
- No random fragmentation/splitting or aggressive padding that can worsen MTU/freezes.

### Residual fingerprinting

Upstream FRP WSS uses the fixed WebSocket path `/~!frp`, which is encrypted inside TLS but can be seen after a successful active TLS probe. Go's TLS ClientHello also has a recognizable implementation fingerprint. v2 deliberately does **not** replace the proven FRP transport with experimental uTLS/random protocol mutations before stability is established.

## Operational safety

- Does **not** install, edit, restart or synchronize Xray/3x-ui.
- FRP binaries live only under `/opt/frp-tunnel-ali/bin`.
- Existing config is backed up before reconfiguration.
- Active reinstall requires typing `APPLY` before project binaries/config are overwritten.
- Config is verified before systemd starts it.
- Restart is explicit and confirmed.
- Rollback validates the archived config first.
- Uninstall removes only this project's service/config/runtime and preserves backups.
- Production bootstrap is pinned to an immutable Git commit.

## Install order

1. Prepare a DNS-only/direct A record for the tunnel domain pointing to the Iran IP.
2. Put a trusted certificate/key for that domain on Iran (existing Let's Encrypt paths are auto-detected).
3. Install **Iran** first and copy the generated secret pair code.
4. Install **Foreign**, paste the pair code and select the existing loopback Xray target.
5. The Foreign installer requires verified TLS and runs an end-to-end public-port health gate.

### Pinned release-candidate install

Use this exact immutable command on Iran first and then Foreign:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/1dddc694c2216fe139250db8410f716aa223dbc7/frp-tunnel-ali-custom/bootstrap.sh)
```

The bootstrap at `1dddc694...` pins installer + CLI content to snapshot `88418b551198ca590b01be52773ae4eb5c9c0e6e`.

### Development branch installer

For branch testing only (not immutable):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/frp-tunnel-ali-custom-v2/frp-tunnel-ali-custom/install.sh)
```

## Management CLI

```bash
frp-tunnel
```

Direct commands:

```bash
frp-tunnel status
frp-tunnel health
frp-tunnel diagnostics
frp-tunnel logs
frp-tunnel backup
frp-tunnel backups
frp-tunnel rollback
frp-tunnel cert
frp-tunnel restart
frp-tunnel target       # Foreign only
frp-tunnel pair-code    # Iran only
frp-tunnel dashboard
frp-tunnel config
frp-tunnel uninstall
```

## Health semantics

Iran:

- systemd active
- control WSS/TLS listener
- DNS still resolves directly to the configured Iran IP
- certificate validity
- public proxy listener
- established user session count

Before Foreign is connected, Iran can legitimately report:

```text
STATUS: 🟡 CONTROL READY — WAITING FOR FOREIGN PROXY
```

If a proxy had registered during the current boot and the public listener later disappears, health reports NOT READY rather than treating it as initial waiting state.

Foreign must pass all of:

- local Xray target reachable
- server TLS identity verified by system CA
- domain resolves to configured Iran IP
- FRP control/work sockets present
- FRP proxy registered
- `DOMAIN:PUBLIC_PORT` end-to-end TCP round trip succeeds

Only then:

```text
STATUS: 🟢 READY FOR TRAFFIC
```

## Capacity starting point

For the historical workload (~20–50 simultaneously online users but many TCP sockets), start with:

```text
poolCount = 24
```

The pool is not a concurrency cap; it is an idle reserve. Increase only if logs show repeated work-connection wait/setup latency. Do not tune by carrier count alone.

## Project phases

Implemented in v0.2.0-rc1:

- core no-mux transport profile
- verified TLS identity
- hysteretic local-target health
- interactive Iran/Foreign installer
- pair-code bootstrap
- health/status/diagnostics
- backups + rollback
- project-isolated binaries
- CI/static/config schema tests

Deferred until the core survives real traffic:

- optional cover reverse-proxy mode / active-probe decoy
- web management dashboard
- Maya1/Maya3 shared-spare selector
- Cloudflare DNS failover
- Telegram control/watchdog

See `AUDIT-2026-08-29.md`.
