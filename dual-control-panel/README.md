# Dual-Foreign Control Panel

A menu-driven management layer for the validated `Dual-Foreign Active/Active Backhaul` data plane.

This branch intentionally preserves the existing `agent/dual-foreign-active-active` implementation as the rollback/reference build. The control panel wraps the known-good installer, sticky routing, fast failover, Xray-aware health, and user-sync components instead of merging `custom-backhaul-v2` or WSS Stealth into this project.

## One-command install

Run on Iran **and** on each Foreign:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-control-panel/dual-control-panel/install.sh)
```

Then use:

```bash
dualctl
```

The first run asks for the server role on a fresh host. If an existing Dual installation is detected, the installer imports it into panel state instead of reinstalling the data plane. On Iran it asks you to confirm the currently-live A/B IPs so a previously replaced Foreign is not accidentally recorded with a stale address.

## Iran wizard

Fresh Iran setup asks for:

- Iran public IPv4
- Foreign A IPv4
- Foreign B IPv4
- WSS domains for A and B

It then installs the validated Dual data plane and automatically applies:

- Active/Active top-level balancing
- source-IP stickiness
- Xray-aware slot health
- fast failover / session shutdown on marked-down slot
- bundle generation for both Foreign servers

The first panel build keeps WSSMux as the required primary profile because the existing validated engine and certificate flow require domains. A no-domain `TCPMux -> plain TCP` profile is deliberately not enabled until separately validated.

## Iran control panel

`dualctl` on Iran provides:

1. Dashboard / full health
2. Replace Foreign A IP
3. Replace Foreign B IP
4. Activate / Drain Foreign
5. User Sync
6. Foreign install / bundle help
7. Restart / repair data plane
8. Show topology
9. Uninstall Dual project

### Safe IP replacement

`Replace Foreign A/B IP` is designed around the failure mode observed during the August 2026 Foreign-A replacement:

1. drain the slot in HAProxy first
2. keep the other Foreign serving reconnects
3. update the existing bundle **without rotating transport tokens**
4. allow the new Foreign control IP in the firewall
5. reject the old Foreign on WSS and that slot's direct control ports
6. restart only the drained Iran-side Backhaul slot to clear stale control channels
7. optionally SCP the updated bundle to the replacement server
8. leave the replacement slot disabled until its health is green
9. activate it explicitly from the panel

This prevents a stale old Foreign control channel from competing with the replacement node.

## Foreign control panel

The same installer is used on Foreign A and Foreign B. Copy the appropriate generated bundle from Iran, run the installer, choose the Foreign role, and point the wizard at the bundle.

Foreign menu:

1. Dashboard / health
2. Restart transports
3. Reinstall / repair from bundle
4. Check Xray listener
5. Show topology
6. Uninstall Dual project

Xray/X-UI must expose the intended inbound on `127.0.0.1:443`. The panel validates that listener but does not delete or uninstall X-UI.

## User sync

The redesigned control plane runs user-sync from the **Iran controller**, so normal management is centralized in one place.

From Iran:

```bash
dualctl
# User Sync -> Setup / reconfigure
```

Recommended final direction:

```text
Foreign A X-UI  ->  Foreign B X-UI
source of truth     mirror
```

The existing v0.3.0 protections remain:

- 30-second timer
- add/update reconciliation
- optional delete mirroring
- empty-primary wipe protection
- maximum delete count / percentage guard
- process locking
- post-sync normalized user-set hash verification

User-sync failure does not stop HAProxy, Backhaul, Xray, or either data path.

## Direct commands

```bash
dualctl                  # interactive panel
dualctl health           # health dashboard
dualctl replace-a        # safe Foreign A IP replacement
dualctl replace-b        # safe Foreign B IP replacement
dualctl users            # user-sync menu
dualctl uninstall        # remove Dual project components
dualctl version
```

## Project isolation

This project remains separate from `custom-backhaul-v2` / WSS Stealth. The control-panel branch uses the stock Backhaul v0.7.2 Dual transport stack:

```text
WSSMux -> TCPMux -> plain TCP
```

No Stealth transport is merged into this branch.
