# Dual-Foreign Active/Active Backhaul

Experimental project for one Iran ingress and two simultaneously-active Foreign exits.

This project is deliberately isolated from `custom-backhaul-v2`. It does not change the v2 branch, installer, or PR.

## Goal

Split new user TCP connections across two Foreign servers so one Foreign IP does not carry the full sustained load/connection pattern.

```text
Users
  |
Iran :443 / HAProxy
  |
  +-- leastconn --> Foreign A slot --> WSSMux -> TCPMux -> plain TCP
  |
  +-- leastconn --> Foreign B slot --> WSSMux -> TCPMux -> plain TCP
```

Normal state is Active/Active. If a whole Foreign slot becomes unhealthy, HAProxy removes that slot and sends new connections to the surviving Foreign.

## Isolation from v2

- Binary: `/usr/local/bin/backhaul-dual`
- Config: `/etc/dual-backhaul`
- State: `/etc/dual-backhaul-ha`
- Services: `dual-bh-*`
- Diagnostic command: `dual-diagnose`

The project can coexist on disk with v2. On the same Iran host only one ingress stack can own public `:443` at a time. `--replace-existing-tunnel` disables known legacy `backhaul*` services without deleting their configs.

## Important behavior

- Load balancing is **per TCP connection**, never per packet.
- Existing connections stay on the Foreign selected when the connection was accepted.
- Each Foreign has independent domains, tokens, control ports, health path and Backhaul processes.
- A and B should preferably be on different providers / ASNs.
- This architecture reduces per-Foreign load. It does **not** reduce Iran traffic usage because all user traffic still crosses Iran.
- It does not guarantee that an IP can never be filtered; the goal is to avoid concentrating the whole traffic signature and volume on one Foreign endpoint.

## Data-plane installer

`install-dual.sh` implements three roles:

- `iran`
- `foreign-a`
- `foreign-b`

Iran creates two root-only bundle files. Copy each bundle directly to its corresponding Foreign; never paste bundle contents into chat/logs.

## User management

Both Foreign Xray instances must ultimately contain the same users because either server may receive any new user connection.

The data-plane installer does **not** copy `x-ui.db` between servers. Database copying is intentionally avoided because it also carries panel/server state.

Planned control-plane component: `user-sync` using the x-ui/Xray management API so Foreign A is the source of truth and user add/update/delete operations are mirrored to Foreign B. Until that component is validated, users must be kept identical on both Foreign Xray instances.

## Current milestone

`v0.2.0`: data-plane installer implemented, not yet production validated.

Before production it must pass:

1. A/B connection distribution under sustained load
2. WSS -> TCPMux -> plain fallback independently inside each slot
3. full Foreign-A and Foreign-B failure/failback
4. reboot persistence
5. user authentication against identical Xray users on both exits
6. no HAProxy routing loops or SNI-control leakage into the user pool
7. clean rollback to the previous single-Foreign stack
