# Dual-Foreign Active/Active Backhaul

One Iran ingress with two simultaneously-active Foreign exits.

This project is deliberately isolated from `custom-backhaul-v2`. It does not merge, replace, or reuse the custom WSS Stealth v2 transport. The current primary transport is stock Backhaul v0.7.2 WSSMux.

## Current production-test topology

- Iran: `5.10.248.50`
- Foreign A: `193.57.9.144`
- Foreign B: `193.57.9.192`
- Domain A: `bh3.biya2film.top`
- Domain B: `bh3b.biya2film.top`

```text
Users
  |
Iran :443 / HAProxy
  |
  +-- sticky Active/Active --> Foreign A slot --> WSSMux -> TCPMux -> plain TCP --> Xray 127.0.0.1:443
  |
  +-- sticky Active/Active --> Foreign B slot --> WSSMux -> TCPMux -> plain TCP --> Xray 127.0.0.1:443
```

Normal state is Active/Active. New source IPs are distributed across A/B, then source-IP stickiness keeps normal reconnects and parallel connections on the same Foreign. If a Foreign/Xray path becomes unhealthy, that slot is removed and reconnects go to the surviving Foreign.

Existing TCP sessions cannot be migrated losslessly after sudden server death; failover means fast reconnect to the surviving slot.

## Isolation from custom Backhaul v2

Dual-Foreign uses its own names and paths:

- binary: `/usr/local/bin/backhaul-dual`
- config: `/etc/dual-backhaul`
- state: `/etc/dual-backhaul-ha`
- services: `dual-bh-*`
- diagnostic command: `dual-diagnose`

The projects can coexist on disk. On the same Iran host only one ingress stack can own public `:443` at a time.

## Transport order inside each Foreign slot

1. stock Backhaul v0.7.2 WSSMux
2. TCPMux
3. plain TCP

Each slot has independent transport tokens, Backhaul processes and health paths.

## HAProxy behavior already validated

The initial per-connection load-balancing design caused visible user IP churn because one user's parallel connections could exit through both Foreign servers.

The current design uses source-IP stickiness plus redispatch. Sticky routing, Active/Active distribution and failover on Foreign/Xray failure have been tested successfully.

Health is Xray-aware: a Foreign slot is considered healthy only when the Foreign-local Xray listener on `127.0.0.1:443` is actually accepting connections.

Fast failover uses aggressive health timing and closes HAProxy sessions associated with a slot when it is marked down so clients reconnect through the surviving slot.

## User synchronization

Both Foreign Xray instances must recognize the same users because HAProxy selects the Foreign before Xray authentication.

The control plane is now implemented under `user-sync/`.

Foreign A is the source of truth. The canonical sync engine mirrors add/update operations to Foreign B, verifies normalized user state by hash and can mirror deletions after explicit enablement. Delete mirroring includes blast-radius guards to prevent a transient empty/bad source response from wiping B.

Install/operate it with the files documented in `USER-SYNC.md`.

The sync controller is intentionally independent from the data plane. A sync failure does not stop HAProxy, Backhaul or Xray; it only delays convergence until a later retry.

## Current milestone

The data plane has passed:

- two-Foreign Active/Active distribution
- source-IP sticky routing
- Xray-aware health checking
- Foreign/Xray failover to the surviving slot on reconnect
- three transports per Foreign: WSSMux -> TCPMux -> plain TCP

The user-sync production candidate is implemented but still requires the live add/update/delete validation sequence against the two production-test X-UI panels.

Remaining before `Production Final`:

1. install canonical user-sync controller
2. validate add on A -> automatic add on B
3. validate edit on A -> automatic update on B
4. explicitly enable delete mirroring and validate delete on A -> automatic delete on B
5. confirm sync/hash state after one full timer cycle
6. reboot test for controller, Foreign A and Foreign B
7. run `dual-diagnose` on all three hosts
8. re-test sticky Active/Active routing and Foreign/Xray failover after reboot
9. record final validated state in `docs/PROJECT-HISTORY.md`

## Security/operations rules

- never commit X-UI credentials, UUID lists, tunnel tokens or secret bundles
- keep `/etc/dual-user-sync/config.json` root-only (`0600`)
- do not copy a live `x-ui.db` between Foreign servers
- preserve failure state long enough to run raw-path diagnostics before reinstall/reboot during unexplained outages
- keep this project separate from `custom-backhaul-v2` unless an explicit future migration is designed and approved
