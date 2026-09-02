# FRP Tunnel — Ali Pro

Production-oriented reverse FRP tunnel profile for Iran↔Foreign paths.

- Iran: nginx WSS/TLS edge on :8443 -> FRPS on 127.0.0.1:18443
- Users: Iran public :443
- Foreign: FRPC connects outbound to the Iran tunnel domain
- Local Foreign target: 127.0.0.1:443 (Xray/3x-ui)
- tcpMux disabled; independent work connections
- automatic nginx capacity tuning
- systemd services and health checks

Install commands are documented after the installer is finalized.
