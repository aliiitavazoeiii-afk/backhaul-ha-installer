#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Pin the known wrapper commit so raw branch caching can never serve an older copy.
BASE_COMMIT="d74aba1add14830a1c9d3c9f46751ffc3afd1dbc"
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${BASE_COMMIT}/dragon-shield/install-dfr-ubuntu24.sh"

tmp=$(mktemp -t dfr-ubuntu24-hotfix.XXXXXXXX.sh)
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry 3 --connect-timeout 15 "$BASE_URL" -o "$tmp"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

# d74 correctly patches both platform guards, but its final grep also matches
# the old guard text embedded inside the Python patcher that prepares managed
# Ingress releases. Remove only those two false-positive verification commands.
lines = []
removed = 0
for line in s.splitlines():
    if line.startswith("! grep -q 'This installer supports Debian only. Detected:' ") and 'runtime platform guard patch failed' in line:
        removed += 1
        continue
    lines.append(line)
if removed != 2:
    raise SystemExit(f'unexpected base wrapper layout: removed={removed}, expected=2')
s = '\n'.join(lines) + '\n'

# Add a real anchored platform verification and a second Ubuntu-only patch pass.
# Upstream DFR intentionally restores captured package/network/host state during
# retry/rollback. On a remote Ubuntu VPS that can recreate firewall/DHCP/resolver
# state and drop the management SSH path. For our canary we use DFR-owned cleanup
# only during automatic retry/failed setup. Explicit uninstall behavior is left
# untouched.
needle = 'log "patched DFR ${DFR_TAG} is ready at ${WORK_ROOT}"'
extra = r'''if grep -Eq '^[[:space:]]*\[\[[[:space:]]*"\$\{ID:-\}"[[:space:]]*==[[:space:]]*"debian"[[:space:]]*\]\][[:space:]]*\|\|[[:space:]]*die[[:space:]]*"This installer supports Debian only\.' "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh"; then
  die "Ingress executable Debian-only runtime guard still present"
fi
if grep -Eq '^[[:space:]]*\[\[[[:space:]]*"\$\{ID:-\}"[[:space:]]*==[[:space:]]*"debian"[[:space:]]*\]\][[:space:]]*\|\|[[:space:]]*die[[:space:]]*"This installer supports Debian only\.' "$WORK_ROOT/main-engine/dragon-fruit-relay-egress.sh"; then
  die "Egress executable Debian-only runtime guard still present"
fi

python3 - "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh" <<'PY_DFR_REMOTE_SAFE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

old_retry = '''    # A failed standalone DFR setup may already have captured host state. Restore
    # it before deleting the partial DFR tree so retrying installation is safe.
    if [[ -f "$MANIFEST_FILE" ]]; then
        restore_package_state || true
        restore_originals || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        restore_unit_state strongswan.service STRONGSWAN || true
        reload_dhcpcd_configuration "${WAN_IF:-}" || true
    fi'''
new_retry = '''    # Ubuntu remote-safe retry: only DFR-owned runtime is cleaned below.
    # Do not restore package/firewall/resolver/DHCP host state automatically,
    # because doing so may drop the management network path on a remote VPS.
    if [[ -f "$MANIFEST_FILE" ]]; then
        warn 'Remote-safe retry: preserving current host package/network state; cleaning DFR-owned residual runtime only.'
    fi'''
if old_retry not in s:
    raise SystemExit('remote-safe retry block not found in ingress')
s = s.replace(old_retry, new_retry, 1)

old_rollback = '''    warn 'Setup failed. Restoring the complete pre-install state...';
    remove_runtime_and_files "$role" || true;
    remove_all_dragonfruit_network_rules || true;
    restore_pre_routevpn_state "$role" || true;
    delete_link_bounded "$old_xfrm" || true;'''
new_rollback = '''    warn 'Setup failed. Removing DFR-owned runtime without restoring host package/network state...';
    remove_runtime_and_files "$role" || true;
    remove_all_dragonfruit_network_rules || true;
    warn 'Remote-safe rollback preserved the current host firewall, resolver, DHCP and package state.';
    delete_link_bounded "$old_xfrm" || true;'''
if old_rollback not in s:
    raise SystemExit('remote-safe rollback block not found in ingress')
s = s.replace(old_rollback, new_rollback, 1)

p.write_text(s)
PY_DFR_REMOTE_SAFE

bash -n "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh"
grep -q 'Remote-safe retry: preserving current host package/network state' "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh" || die "Ingress remote-safe retry patch failed"
grep -q 'Remote-safe rollback preserved the current host firewall' "$WORK_ROOT/main-engine/dragon-fruit-relay-ingress.sh" || die "Ingress remote-safe rollback patch failed"

'''
if needle not in s:
    raise SystemExit('verification insertion point not found')
s = s.replace(needle, extra + needle, 1)
p.write_text(s)
PY

bash -n "$tmp"
printf '[dfr-ubuntu24-hotfix] pinned base=%s; Ubuntu remote-safe retry enabled\n' "$BASE_COMMIT"
exec bash "$tmp" "$@"
