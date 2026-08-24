#!/usr/bin/env bash
set -Eeuo pipefail

CFG=/etc/haproxy/haproxy.cfg
BACKUP_DIR=/root/dual-backhaul-backups

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }
[[ -f "$CFG" ]] || { echo '[x] HAProxy config not found' >&2; exit 1; }
grep -q '^backend slot_a_transports$' "$CFG" || { echo '[x] slot_a_transports not found' >&2; exit 1; }
grep -q '^backend slot_b_transports$' "$CFG" || { echo '[x] slot_b_transports not found' >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/haproxy.pre-wss-tcp-profile.$(date +%Y%m%d-%H%M%S).cfg"
cp -a "$CFG" "$backup"

python3 - "$CFG" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1])
s=p.read_text()
out=[]
for line in s.splitlines():
    stripped=line.lstrip()
    indent=line[:len(line)-len(stripped)]

    # Keep WSS primary. Preserve current health hysteresis.
    if re.match(r'server\s+[ab]_wss\s+', stripped):
        stripped=re.sub(r'\s+backup\b','',stripped)
        stripped=re.sub(r'\s+disabled\b','',stripped)
        out.append(indent+stripped)
        continue

    # TCPMux is retained as an installed diagnostic transport, but removed
    # from production selection because repeated health/data stalls were observed.
    if re.match(r'server\s+[ab]_mux\s+', stripped):
        stripped=re.sub(r'\s+disabled\b','',stripped)
        if ' backup' not in stripped:
            stripped += ' backup'
        stripped += ' disabled'
        out.append(indent+stripped)
        continue

    # Plain TCP is the sole production backup.
    if re.match(r'server\s+[ab]_tcp\s+', stripped):
        stripped=re.sub(r'\s+disabled\b','',stripped)
        if ' backup' not in stripped:
            stripped += ' backup'
        out.append(indent+stripped)
        continue

    out.append(line)

p.write_text('\n'.join(out)+'\n')
PY

if ! haproxy -c -f "$CFG"; then
  cp -a "$backup" "$CFG"
  echo '[x] HAProxy validation failed; backup restored' >&2
  exit 2
fi

systemctl reload haproxy

echo '[+] Stable transport profile applied.'
echo '[+] Production path per Foreign: WSS primary -> plain TCP backup.'
echo '[+] TCPMux remains installed/running for diagnostics but is disabled in HAProxy selection.'
echo "[+] Backup: $backup"
