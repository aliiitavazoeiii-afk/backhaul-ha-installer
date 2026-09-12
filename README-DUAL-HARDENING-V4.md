# XHTTP Dual v4 Hardening

This document supplements `README-DUAL-STICKY.md`. Current code is the source of truth.

## v4 changes

- Controller health loop uses randomized sleep (`check_jitter_ratio`, default 0.30) instead of a fixed 15-second cadence.
- Health checks support multiple HTTPS targets. A second target is tried before a path is declared bad, reducing false failure from one health endpoint.
- F1/F2 probe order is randomized.
- `xhttp-dual netcheck` separates basic Foreign TCP reachability from end-to-end XHTTP/REALITY health.
- `xhttp-dual-set-sni --stage ...` prepares a client SNI update without touching the live tunnel; `--activate-stage` switches only that tunnel service.
- Foreign hardening can build a valid HTTPS decoy on the same Foreign IP and make REALITY forward unauthenticated probes to `127.0.0.1:8443` instead of a remote CDN target.
- Foreign Xray and local decoy services receive conservative systemd sandboxing.
- New Foreign installs verify the Xray release ZIP SHA256 for the pinned v26.3.27 artifacts.
- Fresh Iran installs finish by applying v2, v3, then v4.

## Existing production Iran upgrade

Use `upgrade-dual-hardening.sh`. It installs `controller-v4.py`, a systemd drop-in, and the staged SNI helper. It does not explicitly restart x-ui and does not force a routing sync.

## Existing production Foreign migration

Migrate one Foreign at a time while the other is healthy.

1. Run `upgrade-foreign-reality-hardening.sh prepare` on the selected Foreign. This installs and validates the HTTPS decoy but does not change the running REALITY SNI/target.
2. Copy the printed `DECOY_SNI` and run `xhttp-dual-set-sni --stage f1|f2 <DECOY_SNI>` on Iran. This does not restart the tunnel.
3. Run `upgrade-foreign-reality-hardening.sh activate` on that Foreign.
4. Immediately run `xhttp-dual-set-sni --activate-stage f1|f2` on Iran.
5. Verify `xhttp-dual netcheck`, `xhttp-dual status`, and `xhttp-dual diagnose` before doing the second Foreign.

The selected Foreign is unavailable only between steps 3 and 4. If this window lasts long enough to cross the health threshold, normal failover can change x-ui routing and therefore cause the already-documented short x-ui reconnect.

## Decoy DNS

When no user-owned direct DNS name is supplied, the hardener generates a unique hostname under `nip.io` (or `sslip.io` when `DECOY_ZONE=sslip.io` is set). The generated name resolves directly to that Foreign's own public IPv4. Caddy obtains a public certificate by HTTP-01 on TCP 80; the actual HTTPS target used by REALITY is loopback `127.0.0.1:8443`.

TCP 80 must remain reachable for certificate renewal. TCP 8443 is loopback-only.

To use a user-owned hostname instead, point it directly to the Foreign IP and run prepare with `REALITY_DECOY_DOMAIN=your.name.example`.

## Operational invariants

- F1 local SOCKS remains `127.0.0.1:11818`.
- F2 local SOCKS remains `127.0.0.1:11819`.
- XHTTP stays `mode=auto`.
- Client fingerprint stays `chrome`.
- Existing VLESS UUID, REALITY keypair, short ID and XHTTP path are not rotated by the hardening migration.
- Sticky per-email home/effective routing is unchanged.
- v3 slow/hard/recovery thresholds remain 2/3/5 and 1500 ms unless explicitly tuned.
- Single XHTTP, Mieru, FRP, Maya and unrelated services remain outside this project's cleanup scope.
