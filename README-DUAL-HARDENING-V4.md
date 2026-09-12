# XHTTP Dual Production v4 Hardening

This document supplements `README-DUAL-STICKY.md`. Current code is the source of truth.

## Controller changes

- F1 and F2 no longer emit health probes together on one fixed cadence.
- Each node has an independent randomized schedule. Defaults after `upgrade-dual-hardening.sh` are a healthy base interval of 18 seconds with a 0.55x-1.75x random factor, and a recovery base interval of 10 seconds with the same random factor.
- Health targets are diversified. The controller randomizes the target order and can try a second HTTPS target before declaring a due probe bad.
- F1/F2 due-probe order is randomized.
- `xhttp-dual netcheck` separates basic Foreign TCP reachability from real end-to-end XHTTP/REALITY health.
- v3 latency semantics remain: default `max_latency_ms=1500`, 2 consecutive slow probes => unhealthy, 3 hard failures => unhealthy, 5 good probes => recovered.

The health traffic is only a small part of the data plane and these changes cannot guarantee that an IP will not be filtered; they remove the old obvious paired/fixed health-check cadence and reduce false health decisions.

## Same-server REALITY camouflage

`upgrade-foreign-reality-hardening.sh` now implements the same-server design directly; it does not use `noded.cloud` or another remote CDN as the final REALITY target.

`prepare`:

1. Detects the Foreign public IPv4.
2. Prefers a valid reverse-DNS/PTR hostname when it resolves back to that same Foreign IP. This is typically the most provider/ASN-aligned hostname available automatically.
3. If no usable PTR exists, generates a unique direct hostname under `nip.io` (or `sslip.io` with `DECOY_ZONE=sslip.io`). A user-owned DNS-only hostname can be supplied with `REALITY_DECOY_DOMAIN`.
4. Downloads pinned Caddy v2.11.4 with SHA256 verification.
5. Provisions a public certificate using HTTP-01 on TCP 80.
6. Serves the actual HTTPS decoy only on `127.0.0.1:8443`.
7. Does **not** change the live REALITY server or Iran client.

`activate` changes the Foreign REALITY settings to:

```text
serverNames = [prepared direct hostname]
target      = 127.0.0.1:8443
```

It preserves the existing VLESS UUID, REALITY key pair, short ID, XHTTP path, and public TCP 443 listener. It verifies the unauthenticated TLS fallback through the Foreign's real port 443 and rolls back on activation failure.

TCP 80 must remain reachable for certificate renewal. TCP 8443 is loopback-only. If `prepare` cannot provision and validate a public certificate, it exits without changing the live REALITY configuration.

## Existing production Iran upgrade

Run `upgrade-dual-hardening.sh`. It installs the current `controller-v4.py`, updates the randomized health configuration, installs `xhttp-dual-set-sni`, and restarts only the controller. It does not explicitly restart x-ui and does not force a routing sync.

## Existing production Foreign migration

Migrate one Foreign at a time while the other is healthy.

1. On the selected Foreign run `upgrade-foreign-reality-hardening.sh prepare`. This builds and validates the local HTTPS decoy without changing live REALITY.
2. Copy the printed `NEW_SNI` and on Iran run `xhttp-dual-set-sni --stage f1|f2 <NEW_SNI>`. Staging makes no live change.
3. To avoid an automatic failover decision during the short SNI transition, stop only `xhttp-dual-controller.service` on Iran.
4. On that Foreign run `upgrade-foreign-reality-hardening.sh activate`.
5. Immediately on Iran run `xhttp-dual-set-sni --activate-stage f1|f2`.
6. Start `xhttp-dual-controller.service` again and verify `xhttp-dual netcheck`, `xhttp-dual status`, and `xhttp-dual diagnose`.
7. Repeat for the second Foreign only after the first is verified healthy.

Only users currently pinned to the selected Foreign can see a brief reconnect during steps 4-5. The other tunnel and x-ui are not deliberately restarted by this migration. Normal routing failover/failback still uses the existing x-ui template mechanism and can therefore cause the previously documented short x-ui reconnect when a real health transition occurs.

## Fresh installs

- Fresh Foreign installs use verified Xray v26.3.27 and run the same hardener after the base Foreign service is created.
- Fresh Iran installs finish by applying v2 canonical 3x-ui user routing, v3 latency health, then this production v4 controller.

## Operational invariants

- F1 local SOCKS: `127.0.0.1:11818`
- F2 local SOCKS: `127.0.0.1:11819`
- XHTTP mode: `auto`
- Client fingerprint: `chrome`
- Sticky identity: per VLESS email, with persisted `home` and `effective`
- Existing VLESS UUID, REALITY key pair, short ID and XHTTP path are not rotated by the hardening migration
- Single XHTTP, Mieru, FRP, Maya and unrelated services remain outside this project's cleanup scope
