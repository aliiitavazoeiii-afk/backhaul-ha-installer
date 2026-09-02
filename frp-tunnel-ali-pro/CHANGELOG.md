# Changelog

## 1.0.0
- Unified Iran/Foreign installer.
- Nginx TLS/WSS edge with Let's Encrypt automation.
- FRPS loopback-only control backend.
- Four independent FRPC shards with shared load-balancer group.
- tcpMux disabled; total idle work-connection reserve 24.
- Nginx capacity hardening (65535 worker connections, raised file limit).
- No Xray/3x-ui modification.
- Health and diagnostics commands.
