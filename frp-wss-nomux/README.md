# FRP WSS no-mux (parallel migration from Aegis)

Production-oriented FRP deployment for the existing Aegis Single topology.

## Goals

- Keep 3x-ui/Xray untouched.
- Keep Aegis running during testing and migration.
- Carry FRP control/work connections as WSS on the existing carrier domain and Iran public port 443.
- Disable FRP TCP stream multiplexing (`transport.tcpMux = false`) so each FRP connection uses a real transport connection instead of sharing one yamux TCP session.
- Use a pool of pre-established work connections for short/bursty traffic.
- Provide a public test port before production cutover.
- Cut over and roll back with HAProxy graceful reloads.

## Topology

```text
Foreign frpc
  -> WSS/TLS to IRAN_IP:443, SNI/Host = carrier domain
  -> existing HAProxy carrier SNI route
  -> existing Nginx TLS endpoint
  -> /~!frp
  -> frps 127.0.0.1:18081

User test traffic
  -> IRAN_IP:2443
  -> HAProxy test frontend
  -> frps proxy 127.0.0.1:10445
  -> independent WSS work connection(s)
  -> Foreign Xray 127.0.0.1:443

Production after cutover
  -> IRAN_IP:443
  -> HAProxy user_gateway
  -> 127.0.0.1:10445 (FRP)
  -> Foreign Xray 127.0.0.1:443
```

The existing Aegis services and `127.0.0.1:10443` remain available for rollback.

## Version pin

FRP `v0.70.1` release binaries are downloaded from the official `fatedier/frp` release and verified with pinned SHA256 values for linux/amd64 and linux/arm64.

## Iran install

```bash
bash install.sh --role iran --iran-ip <IRAN_IP> --domain <EXISTING_AEGIS_DOMAIN>
```

The installer writes `/root/frp-nomux.env` for the Foreign server.

## Foreign install

Copy `install.sh` and `/root/frp-nomux.env` to the Foreign server, then:

```bash
bash install.sh --role foreign --bundle /root/frp-nomux.env
```

The installer refuses to proceed if Xray is not listening on `127.0.0.1:443`.

## Test

Before production cutover, clone one working user config and change only its port to `2443`. Keep the same Iran IP, UUID, Reality SNI, public key, fingerprint, etc.

Check Iran:

```bash
frpctl status
```

## Production cutover

```bash
frpctl cutover
```

This changes only the HAProxy `user_gateway` backend and performs a graceful HAProxy reload. Existing Aegis connections are allowed to drain; new connections use FRP.

## Rollback

```bash
frpctl rollback
```

New connections return to the saved Aegis backend with a graceful HAProxy reload.

## Remove the public test port

```bash
frpctl test-off
```

## Notes

- The Internet-facing WSS TLS session terminates at the existing Nginx carrier endpoint. The frps listener itself is loopback-only and therefore accepts the post-TLS WebSocket connection from Nginx.
- FRP's WebSocket transport path in v0.70.1 is `/~!frp`; the installer adds only that exact Nginx location.
- The FRP proxy listener is bound only to `127.0.0.1:10445`; it is not publicly exposed directly.
- Authentication uses a random 256-bit token and also authenticates heartbeat and new work connections.
