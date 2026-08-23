# User Sync Control Plane

## Why it is required

The Iran balancer chooses Foreign A or Foreign B **before** Xray authenticates the user. Therefore both Xray instances must contain the same UUID/user definitions.

Without synchronization, adding a user only to A would make that user work roughly half the time: connections routed to A would authenticate and connections routed to B would fail.

## Final operator workflow

The intended workflow is:

```text
Add/update/delete user once
        |
        v
Foreign A / primary management source
        |
        +---- user-sync ----> Foreign B
```

The operator should not have to manually create the same user twice.

## Design rules

1. Do not copy `x-ui.db` between servers.
2. Do not share a live SQLite database over the network.
3. Do not make data-plane availability depend on the sync controller.
4. Foreign A and B keep independent Xray processes and local state.
5. Synchronization uses the management/API layer and is idempotent.
6. A sync failure must raise an alert but must never stop either tunnel.
7. Credentials/tokens stay in a root-readable `0600` secrets file and are never committed to Git.

## Planned implementation

`dualctl users sync`

- read the configured inbound/user set from primary Foreign A
- read the corresponding inbound/user set from Foreign B
- compare by stable identity (UUID/email/inbound mapping)
- create missing users on B
- update changed users on B
- remove users from B only when explicit delete mirroring is enabled
- verify the resulting user-set hash on A and B

An optional systemd timer/controller can run the same idempotent sync periodically after manual validation.

## Safety mode

The first version will default to additive/update-only synchronization. Destructive deletion mirroring will require an explicit setting so a temporary API/read problem cannot wipe users from the secondary exit.
