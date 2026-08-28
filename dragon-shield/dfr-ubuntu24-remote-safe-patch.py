#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: dfr-ubuntu24-remote-safe-patch.py <ingress-script>")

p = Path(sys.argv[1])
s = p.read_text()

old_retry = """    # A failed standalone DFR setup may already have captured host state. Restore
    # it before deleting the partial DFR tree so retrying installation is safe.
    if [[ -f \"$MANIFEST_FILE\" ]]; then
        restore_package_state || true
        restore_originals || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        restore_unit_state strongswan.service STRONGSWAN || true
        reload_dhcpcd_configuration \"${WAN_IF:-}\" || true
    fi"""
new_retry = """    # Ubuntu remote-safe retry: only DFR-owned runtime is cleaned below.
    # Do not restore package/firewall/resolver/DHCP host state automatically,
    # because doing so may drop the management network path on a remote VPS.
    if [[ -f \"$MANIFEST_FILE\" ]]; then
        warn 'Remote-safe retry: preserving current host package/network state; cleaning DFR-owned residual runtime only.'
    fi"""

if old_retry not in s:
    raise SystemExit("remote-safe retry block not found in ingress")
s = s.replace(old_retry, new_retry, 1)

old_rollback = """    warn 'Setup failed. Restoring the complete pre-install state...';
    remove_runtime_and_files \"$role\" || true;
    remove_all_dragonfruit_network_rules || true;
    restore_pre_routevpn_state \"$role\" || true;
    delete_link_bounded \"$old_xfrm\" || true;"""
new_rollback = """    warn 'Setup failed. Removing DFR-owned runtime without restoring host package/network state...';
    remove_runtime_and_files \"$role\" || true;
    remove_all_dragonfruit_network_rules || true;
    warn 'Remote-safe rollback preserved the current host firewall, resolver, DHCP and package state.';
    delete_link_bounded \"$old_xfrm\" || true;"""

if old_rollback not in s:
    raise SystemExit("remote-safe rollback block not found in ingress")
s = s.replace(old_rollback, new_rollback, 1)

p.write_text(s)

if "Remote-safe retry: preserving current host package/network state" not in s:
    raise SystemExit("remote-safe retry verification failed")
if "Remote-safe rollback preserved the current host firewall" not in s:
    raise SystemExit("remote-safe rollback verification failed")
