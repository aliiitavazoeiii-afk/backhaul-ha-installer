# Project status

Ali Pro v1.0.0 installer is finalized for first production deployment.

Release gate for each new server pair:
1. Tunnel domain resolves directly to Iran.
2. TCP/80, control port (default 8443), and public port (default 443) are reachable on Iran as required.
3. Existing Foreign Xray inbound listens on 127.0.0.1:443 (or selected local port).
4. Foreign can establish TLS/HTTP to the Iran tunnel domain/control port.
5. All four FRPC shard services are active.
6. Public Iran user port passes the end-to-end TCP gate.

No claim of zero packet loss or permanent filter resistance is made; health/diagnostics are included for field verification.
