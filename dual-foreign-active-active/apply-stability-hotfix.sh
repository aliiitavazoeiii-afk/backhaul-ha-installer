#!/usr/bin/env bash
set -Eeuo pipefail

CFG=/etc/haproxy/haproxy.cfg
BACKUP_DIR=/root/dual-backhaul-backups

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }
[[ -f "$CFG" ]] || { echo '[x] HAProxy config not found' >&2; exit 1; }
grep -q '^backend vpn_users$' "$CFG" || { echo '[x] vpn_users backend not found' >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/haproxy.pre-stability-hotfix.$(date +%Y%m%d-%H%M%S).cfg"
cp -a "$CFG" "$backup"

python3 - "$CFG" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

transport_names = ('a_wss','a_mux','a_tcp','b_wss','b_mux','b_tcp')
slot_names = ('foreign_a','foreign_b')

out=[]
for line in s.splitlines():
    stripped=line.lstrip()
    indent=line[:len(line)-len(stripped)]

    m=re.match(r'server\s+(\S+)\s+', stripped)
    if not m:
        out.append(line)
        continue

    name=m.group(1)

    if name in transport_names:
        # A single one-second health miss must not kill live user sessions.
        stripped=re.sub(r'\s+inter\s+\S+\s+fall\s+\d+\s+rise\s+\d+', '', stripped)
        stripped=re.sub(r'\s+on-marked-down\s+shutdown-sessions', '', stripped)

        # Insert stable transport hysteresis immediately after check port N.
        stripped=re.sub(
            r'(\bcheck\s+port\s+\d+)',
            r'\1 inter 2s fall 2 rise 5',
            stripped,
            count=1,
        )
        out.append(indent+stripped)
        continue

    if name in slot_names:
        # Whole-Foreign failure still closes sessions so clients reconnect,
        # but only after confirmed failure; recovery requires a stable window.
        stripped=re.sub(r'\s+inter\s+\S+\s+fall\s+\d+\s+rise\s+\d+', '', stripped)
        stripped=re.sub(r'\s+on-marked-down\s+shutdown-sessions', '', stripped)
        stripped=re.sub(
            r'(\bcheck\s+port\s+\d+)',
            r'\1 inter 2s fall 2 rise 10 on-marked-down shutdown-sessions',
            stripped,
            count=1,
        )
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

echo '[+] Dual stability hotfix applied.'
echo '[+] Transport health: inter=2s fall=2 rise=5 (about 4s fail / 10s recovery).'
echo '[+] Transport-level shutdown-sessions removed.'
echo '[+] Foreign slot health: inter=2s fall=2 rise=10 (about 4s fail / 20s recovery).'
echo '[+] Whole-slot shutdown-sessions retained only after confirmed slot failure.'
echo "[+] Backup: $backup"
