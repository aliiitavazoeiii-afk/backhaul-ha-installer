# Dual WSS Stealth Audit

Validated dependency chain for the clean two-Foreign WSS-only topology.

- Upstream Backhaul source is pinned to commit `df7966f8f725837a680ea7b90bd37ea52666c277` (v0.7.2).
- Custom patch set is pinned to commit `e9111c6d78a922972482e3de720d1f82dca062d8`.
- Required patch files exist: `apply_patch.py`, `fix_wsmux_config.py`, `fix_wss_alpn.py`.
- Upstream `go.mod` requires Go 1.23.1.
- Builder uses existing Go >= 1.23.1 when present, otherwise pinned Go 1.24.12 with SHA-256 verification.
- Source retrieval uses `git fetch` of the exact commit instead of redirect-based GitHub archive downloads.
- Builder runs `go test ./...` before installing the custom binary.
- Built binary must contain `ws_control_path`, `ws_tunnel_path`, and `tls_skip_verify` capabilities.
- Iran generates two isolated bundles, one per Foreign slot.
- HAProxy only balances the two WSS Stealth data paths; TCPMux and plain TCP are not part of this topology.
- HAProxy health checks traverse the same WSS path and reach the Foreign Xray-aware local health endpoint.
