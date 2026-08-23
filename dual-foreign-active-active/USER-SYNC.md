# User Sync Control Plane

## Purpose

HAProxy chooses Foreign A or Foreign B before Xray authenticates the client. Both Foreign Xray instances therefore need the same client definitions.

The control-plane workflow is:

```text
Operator changes user once in X-UI on Foreign A
                 |
                 v
        dual-user-sync controller
                 |
                 v
          X-UI on Foreign B
```

Foreign A is the management source of truth. Foreign B remains an independent Xray/X-UI node; the data plane never depends on the sync process being alive.

## Canonical implementation

The production candidate is:

`user-sync/dual_user_sync.py`

Current version: `0.3.0`.

The old separate `dual_user_sync_v2.py` implementation was removed so there is only one canonical sync engine.

The installer creates:

- `/usr/local/lib/dual-user-sync/dual_user_sync.py`
- `/usr/local/bin/dual-usersync`
- `/etc/dual-user-sync/config.json` (`0600`)
- `dual-user-sync.service`
- `dual-user-sync.timer`

Default timer interval: 30 seconds.

## What is synchronized

For the configured Xray inbound the controller:

1. logs into both X-UI panels
2. discovers the matching inbound
3. indexes clients by stable identity
4. creates clients missing on B
5. updates changed client fields on B
6. optionally removes clients that exist only on B
7. re-reads B and verifies the normalized client set with SHA-256

Local-only panel metadata such as `created_at` and `updated_at` is ignored so harmless per-node metadata does not cause endless update loops.

## Operator commands

```bash
dual-usersync check
dual-usersync sync
dual-usersync status
dual-usersync logs
```

`check` is read-only. `sync` performs the idempotent A -> B reconciliation immediately.

## Delete safety

Deletion mirroring is OFF after installation.

Enable it only after add/update tests have passed:

```bash
dual-usersync enable-delete
```

Disable it again with:

```bash
dual-usersync disable-delete
```

Even when deletion mirroring is enabled, v0.3.0 has a blast-radius guard. By default it refuses:

- an apparent full wipe when A suddenly returns zero clients while B still has users
- more than 25 deletions in one reconciliation
- a deletion plan larger than 50% of B's current client set

These thresholds live under `delete_guard` in `/etc/dual-user-sync/config.json` and should only be relaxed for an intentional bulk operation.

## Concurrency and failure behavior

A process lock prevents a manual sync and the systemd timer from modifying B simultaneously.

A panel/API/sync failure exits non-zero and is recorded in the systemd journal. It does not stop HAProxy, Backhaul, Xray, or either Foreign data path. The next timer run retries reconciliation.

Credentials remain only in the root-readable local config and must never be committed to Git or pasted into chat/logs.

## Production validation sequence

Before enabling exact delete mirroring permanently:

1. `dual-usersync check` must discover the intended `127.0.0.1:443` inbound on both Foreign nodes.
2. Add a temporary user on Foreign A only; within one timer cycle it must appear on B with identical normalized fields.
3. Edit expiry/limit/enable state on A; B must converge automatically.
4. Run `dual-usersync enable-delete`.
5. Delete the temporary user on A; B must remove it automatically.
6. `dual-usersync check` must report no pending add/update operations and a matching primary-set hash.
7. Reboot the controller host, Foreign A, and Foreign B as planned; after boot the timer must be active and a fresh add/edit/delete test must still converge.
8. Run `dual-diagnose` on Iran and both Foreign nodes and re-test Active/Active sticky routing plus Foreign/Xray failover.

Only after this sequence passes should the Dual-Foreign stack be marked Production Final.
