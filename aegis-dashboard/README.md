# Aegis Control Dashboard

A loopback-only production controller for the validated Aegis Single Primary topology.

## Topology

```text
users -> IRAN:443 -> HAProxy -> Aegis primary -> FOREIGN PRIMARY Xray 127.0.0.1:443
                              \\-> direct BACKUP FOREIGN:443 (HAProxy `backup` only)
```

The dashboard intentionally does **not** implement active/active load balancing or continuous user synchronization.

## Inputs

The operator supplies only:

- Aegis carrier domain (must resolve to the Iran IP)
- Iran IPv4
- Foreign Primary IPv4
- Foreign Backup IPv4

Remote provisioning requires root SSH key access from the Iran controller. The dashboard generates an Ed25519 key and displays the public key. Passwords are never accepted or stored.

## Management security

- HTTP listener: `127.0.0.1:8787` only
- Access through an SSH local forward
- High-entropy local bearer bootstrap token, converted to an HttpOnly + SameSite=Strict cookie
- POST requests reject unexpected Origin values
- Topology fields are validated before use
- Only fixed root SSH destinations from validated IPv4 fields are used
- Provisioning logs do not contain SSH private keys or panel passwords

## 3x-ui v2.9.4

For a new Foreign node, the controller installs the official `MHSanaei/3x-ui` v2.9.4 release using fixed release asset SHA256 values. It does not call the interactive upstream installer.

Supported production hosts for unattended 3x-ui installation: Debian/Ubuntu with systemd, amd64 or arm64.

Existing nodes are preserved when all of these are already true:

- `/usr/local/x-ui/x-ui -v` is exactly `2.9.4`
- `/etc/x-ui/x-ui.db` exists
- `x-ui.service` is active
- Xray accepts TCP on `127.0.0.1:443`

### Golden template

A one-time SQLite snapshot of `/etc/x-ui/x-ui.db` is stored on the Iran controller at:

`/var/lib/aegis-dashboard/x-ui-template.db`

It is used only when provisioning a new/replacement Foreign node. There is no periodic or continuous user sync.

The snapshot is made with SQLite `.backup` and verified with `PRAGMA quick_check`. A replacement node also validates the database before starting 3x-ui. If copied panel certificate paths refer to files that do not exist on the replacement, only stale panel/subscription certificate path settings are cleared so x-ui can start safely.

Use **Refresh Golden Template** manually when the desired provisioning baseline changes.

## Provisioning order

1. Validate domain -> Iran IPv4.
2. Validate root SSH key access to Primary and Backup.
3. Capture a Golden Template if none exists.
4. Preserve healthy existing 3x-ui v2.9.4 nodes, otherwise install verified v2.9.4 + Golden Template.
5. Install/reconcile Aegis on Iran.
6. Install/reconcile Aegis client on Primary.
7. Install/reconcile the direct standby relay on Backup.
8. Add Backup to HAProxy with the `backup` flag.
9. Require Aegis `primary-ready: UP`.
10. Require Iran -> Backup TCP reachability.
11. Require `x-ui` active on both Foreign nodes.

A failed preflight stops before the dependent mutation. Existing Aegis and direct-backup installers retain their own config validation and backup/rollback guards.

## Existing production onboarding

Installing the dashboard itself does not reconcile or restart the VPN topology. For an already-working deployment:

1. Install the dashboard on Iran.
2. Add the displayed controller SSH public key to both Foreign root `authorized_keys` files.
3. Enter the four topology values.
4. Use **Check SSH**.
5. Use **Refresh Golden Template** once to establish the known-good 3x-ui baseline.
6. Do not press **Deploy / Reconcile** unless an actual reconciliation/replacement is intended.

## Files

- `app.py` - loopback HTTP control plane
- `provision.py` - validated SSH provisioning and health checks
- `ui.html` - dashboard UI
- `remote/install-3xui-2.9.4.sh` - deterministic 3x-ui installer
- `install-dashboard.sh` - controller installer (created only after dashboard code is CI-pinned)
