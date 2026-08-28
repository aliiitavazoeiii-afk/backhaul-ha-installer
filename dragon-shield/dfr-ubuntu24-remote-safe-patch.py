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

old_finalize = """finalize_ingress_after_tunnel ()
{
    start_unit_checked dragon-fruit-relay-routing.service 'Selective routing service' || return 1
    remove_systemd_resolved || true
    configure_dhcpcd_resolver_hook || warn 'Could not stop dhcpcd from managing /etc/resolv.conf. The tunnel remains active, but DHCP may replace the managed resolver.'
    write_ingress_dns_files no || warn 'Could not rebuild the static resolver definition. The tunnel remains active.'
    write_ingress_healthcheck_files || warn 'Could not rebuild the health-monitor definition. The tunnel remains active.'
    timeout 15s systemctl daemon-reload >>\"$LOG_FILE\" 2>&1 || warn 'systemd did not reload the resolver and monitor units within 15 seconds.'
    if start_unit_checked dragon-fruit-relay-dns.service 'Static resolver service'; then
        resolver_runtime_ok || warn 'The resolver unit ran, but /etc/resolv.conf is not using the managed resolver file.'
    else
        warn 'The encrypted tunnel remains active, but the static resolver service needs Repair.'
    fi
    start_health_monitor_best_effort || true
    return 0
}"""
new_finalize = """finalize_ingress_after_tunnel ()
{
    start_unit_checked dragon-fruit-relay-routing.service 'Selective routing service' || return 1
    warn 'Ubuntu remote-safe mode: preserving host DHCP, systemd-resolved and /etc/resolv.conf; DFR will not replace the VPS management resolver.'
    write_ingress_healthcheck_files || warn 'Could not rebuild the health-monitor definition. The tunnel remains active.'
    timeout 15s systemctl daemon-reload >>\"$LOG_FILE\" 2>&1 || warn 'systemd did not reload the health monitor within 15 seconds.'
    systemctl disable --now dragon-fruit-relay-dns.service >/dev/null 2>&1 || true
    start_health_monitor_best_effort || true
    return 0
}"""

if old_finalize not in s:
    raise SystemExit("remote-safe finalize block not found in ingress")
s = s.replace(old_finalize, new_finalize, 1)

old_health = """activate_data_path() {
    timeout 15s systemctl start dragon-fruit-relay-routing.service >/dev/null 2>&1 || return 1
    if resolver_runtime_ok; then
        timeout 15s systemctl start dragon-fruit-relay-dns.service >/dev/null 2>&1 || return 1
    else
        logger -t dragon-fruit-relay-healthcheck '/etc/resolv.conf was replaced; restarting the managed DNS service'
        timeout 15s systemctl restart dragon-fruit-relay-dns.service >/dev/null 2>&1 || return 1
    fi
}"""
new_health = """activate_data_path() {
    # Ubuntu remote-safe mode: keep the host resolver/DHCP path untouched.
    timeout 15s systemctl start dragon-fruit-relay-routing.service >/dev/null 2>&1 || return 1
    return 0
}"""

if old_health not in s:
    raise SystemExit("remote-safe healthcheck resolver block not found in ingress")
s = s.replace(old_health, new_health, 1)

p.write_text(s)

checks = [
    "Remote-safe retry: preserving current host package/network state",
    "Remote-safe rollback preserved the current host firewall",
    "Ubuntu remote-safe mode: preserving host DHCP, systemd-resolved and /etc/resolv.conf",
    "Ubuntu remote-safe mode: keep the host resolver/DHCP path untouched",
]
for check in checks:
    if check not in s:
        raise SystemExit(f"remote-safe verification failed: {check}")
