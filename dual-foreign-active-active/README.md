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

## Important behavior

- Load balancing is **per TCP connection**, never per packet.
- Existing connections stay on the Foreign selected when the connection was accepted.
- Each Foreign has independent domains, tokens, control ports, health path and Backhaul processes.
- A and B should preferably be on different providers / ASNs.
- This architecture reduces per-Foreign load. It does **not** reduce Iran traffic usage because all user traffic still crosses Iran.
- It does not guarantee that an IP can never be filtered; the goal is to avoid concentrating the whole traffic signature and volume on one Foreign endpoint.

## User management

Both Foreign Xray instances must ultimately contain the same users because either server may receive any new user connection.

The data-plane installer does **not** copy `x-ui.db` between servers. Database copying is intentionally avoided because it also carries panel/server state.

Planned control-plane component: `user-sync` using the x-ui/Xray management API so Foreign A is the source of truth and user add/update/delete operations are mirrored to Foreign B. Until that component is validated, users must be kept identical on both Foreign Xray instances.

## Roles

### Iran

Generates two Foreign-specific secret bundles and installs:

- six isolated Backhaul server transports (three per Foreign)
- SNI routing for the two WSS control domains
- two local Foreign slots with transport fallback
- top-level `leastconn` Active/Active balancing between slots

### Foreign A / Foreign B

Each installs three Backhaul clients and a loopback-only health endpoint. Xray is expected to listen on `127.0.0.1:443`.

## Current milestone

`v0.1.0`: architecture scaffold and installer work in progress. Do not deploy to production until lab validation covers:

1. A/B connection distribution under sustained load
2. WSS -> TCPMux -> plain fallback independently inside each slot
3. full Foreign-A and Foreign-B failure/failback
4. reboot persistence
5. user authentication against identical Xray users on both exits
6. no HAProxy routing loops or SNI-control leakage into the user pool
