# Security model

Ali Pro exposes only the Iran public user port and a normal TLS/WSS control edge. FRPS itself binds to loopback. Foreign FRPC initiates the tunnel outbound to the Iran domain and targets only local loopback Xray.

Secrets (FRP token, pair code, load-balancer key) are generated at install time, stored mode 0600, and must never be committed to GitHub.

The project does not edit, restart, synchronize, or reconfigure Xray/3x-ui.
