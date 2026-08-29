# FRP Tunnel — Ali Tavazoei Custom Version

Production-oriented two-server FRP profile for forwarding a TCP service from a Foreign VPS to an Iran VPS.

## Architecture

```text
Users -> IRAN_PUBLIC_IP:443 -> frps -> WSS/TLS control/work connections -> frpc -> 127.0.0.1:443 (Xray/3x-ui)
```

The installer **does not install, edit, restart, or synchronize Xray/3x-ui**.

## Main stability changes

The critical setting is `transport.tcpMux = false` on both sides. FRP normally can multiplex many logical streams over one underlying TCP connection. On lossy paths, one shared carrier can amplify head-of-line blocking across unrelated users. This profile uses independent work connections instead.

Defaults:

- FRP core pinned to `v0.71.0` with SHA-256 verification.
- WSS + TLS transport with domain SNI.
- FRP custom TLS first byte disabled.
- 24 pre-established independent work connections by default; server limit 64.
- Compression disabled for encrypted/video traffic.
- TCP health check of the Foreign local target every 10 seconds.
- Automatic reconnect (`loginFailExit = false`) plus systemd `Restart=always`.
- Local-only FRP dashboards: Iran `127.0.0.1:7500`, Foreign `127.0.0.1:7400`.
- Interactive terminal panel: `frp-tunnel`.
- Pair-code workflow so the Iran-generated token/config is copied once to Foreign.
- Config validation before startup.
- Backup before reinstall.

## DPI / filtering profile

The transport uses WSS/TLS rather than plaintext FRP TCP, so the control/work traffic is encrypted and carries domain SNI. This reduces obvious plaintext/protocol signatures. It does **not** claim to be impossible to fingerprint or block: active probing, IP reputation, traffic analysis, endpoint blocking, and TLS metadata can still disrupt a tunnel.

The profile intentionally avoids packet fragmentation, random packet splitting, and aggressive padding. Those features can increase overhead, worsen MTU behavior, and create the same video-freeze symptoms the stable profile is designed to reduce.

## Install

Run on Iran first, then Foreign:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/frp-tunnel-ali-custom-v1/frp-tunnel-ali-custom/install.sh)
```

### Iran

Choose `IRAN`. The installer asks for:

- Iran public IPv4
- Foreign public IPv4
- tunnel domain (must point to Iran)
- FRP WSS/TLS control port (default `8443`)
- public user port (default `443`)

It prints a one-line `PAIR CODE` at the end.

### Foreign

Run the same installer, choose `FOREIGN`, paste the pair code, then confirm:

- Foreign local target IP (default `127.0.0.1`)
- Foreign local target port (default `443`)
- pre-established pool count (default `24`)

## Terminal panel

```bash
frp-tunnel
```

Direct commands:

```bash
frp-tunnel status
frp-tunnel health
frp-tunnel logs
frp-tunnel restart
frp-tunnel target      # Foreign only
frp-tunnel pair-code   # Iran only
frp-tunnel config
```

## Health checks

Iran side reports:

- systemd service state
- WSS/TLS control listener
- public user listener
- established user TCP session count

Foreign side reports:

- local Xray target state
- FRP control/work connections to Iran
- FRP proxy login/status

## Operational safeguards

- Existing listeners are never killed automatically.
- Installer warns when requested Iran ports are occupied.
- Restart requires confirmation because active sessions can be interrupted.
- Uninstall does not touch Xray/3x-ui.
- Secrets are redacted from the panel config view.

## Capacity tuning

For roughly 50 concurrent users, start with `poolCount = 24`. If the workload has many short concurrent connections, `32` can reduce work-connection setup latency. Do not increase it blindly: every independent WSS/TLS work connection consumes sockets and memory.

## Important limitation

No TCP tunnel can guarantee zero freezes. This profile removes the major *cross-user shared-TCP multiplexing* failure mode, but packet loss can still stall an individual TCP stream. Use the health panel and logs to distinguish control-channel failure, local-target failure, and path degradation before changing parameters.
