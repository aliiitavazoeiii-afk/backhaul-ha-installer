# Three-path automatic failover

Version 1.3.0 adds a third independent Backhaul transport so the user-facing VPN can keep working when one or two tunnel transports are unavailable.

## Priority

HAProxy health-checks every transport end-to-end and uses this priority:

1. WSSMux primary
2. TCPMux backup
3. plain TCP emergency backup

The plain TCP path is intentionally a backup. It keeps its Backhaul control/pool connections ready but receives user VPN traffic only when the higher-priority paths are unavailable.

## Paths

### WSSMux

- Foreign client -> backbone domain `:443`
- HAProxy SNI routes backbone traffic to Iran Backhaul WSSMux `127.0.0.1:8443`
- user data mapping: Iran `10443` -> Foreign `127.0.0.1:443`
- health mapping: Iran `10444` -> Foreign `127.0.0.1:18090`
- diagnostic throughput mapping: Iran `10445` -> Foreign `127.0.0.1:5201`

### TCPMux

- Foreign client -> Iran `:3080`
- user data mapping: Iran `11443` -> Foreign `127.0.0.1:443`
- health mapping: Iran `11444` -> Foreign `127.0.0.1:18090`
- diagnostic throughput mapping: Iran `11445` -> Foreign `127.0.0.1:5201`

### plain TCP

- Foreign client -> Iran `:3081`
- user data mapping: Iran `12443` -> Foreign `127.0.0.1:443`
- health mapping: Iran `12444` -> Foreign `127.0.0.1:18090`
- diagnostic throughput mapping: Iran `12445` -> Foreign `127.0.0.1:5201`

The Iran firewall permits control ports `3080` and `3081` only from the configured Foreign IP. The user-facing public ingress remains HAProxy `:443`.

## Automatic behavior

HAProxy checks the health mappings every two seconds. A transport is considered usable only if it can reach the Foreign health endpoint through its own Backhaul data-plane.

This means a Backhaul process can still be `active` while its transport is rejected by HAProxy if the actual end-to-end data-plane is stalled.

If WSSMux fails, HAProxy uses TCPMux. If TCPMux also fails, HAProxy uses plain TCP. When a higher-priority transport becomes healthy again, new connections return to the preferred path automatically.

## Diagnostics

`tunnel-diagnose` checks all three transports independently.

`tunnel-diagnose --deep` compares throughput for all three transports in both directions.

`tunnel-diagnose --repair` is conservative: on Foreign it restarts only a transport whose control path is reachable but whose data-plane health traffic is stale. HAProxy failover itself does not depend on repair.

## Resource impact

The third transport adds one Backhaul service on each server and a small pre-established connection pool. In normal operation it is an idle emergency path; user traffic is not duplicated across all transports.
