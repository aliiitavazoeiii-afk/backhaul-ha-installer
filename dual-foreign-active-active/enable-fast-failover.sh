#!/usr/bin/env bash
set -Eeuo pipefail

CFG=/etc/haproxy/haproxy.cfg
BACKUP_DIR=/root/dual-backhaul-backups

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }
[[ -f "$CFG" ]] || { echo '[x] HAProxy config not found' >&2; exit 1; }

grep -q '^backend vpn_users$' "$CFG" || { echo '[x] vpn_users backend not found' >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/haproxy.pre-fast-failover.$(date +%Y%m%d-%H%M%S).cfg"
cp -a "$CFG" "$backup"

python3 - "$CFG" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()

# Make both transport-level and slot-level health transitions fast.
patterns = [
    r'(server a_wss .*?check port 10444 )inter 3s fall 2 rise 3',
    r'(server a_mux .*?check port 11444 )inter 3s fall 2 rise 3',
    r'(server a_tcp .*?check port 12444 )inter 3s fall 2 rise 3',
    r'(server b_wss .*?check port 20444 )inter 3s fall 2 rise 3',
    r'(server b_mux .*?check port 21444 )inter 3s fall 2 rise 3',
    r'(server b_tcp .*?check port 22444 )inter 3s fall 2 rise 3',
    r'(server foreign_a .*?check port 15011 )inter 3s fall 2 rise 3',
    r'(server foreign_b .*?check port 15012 )inter 3s fall 2 rise 3',
]
for pat in patterns:
    s = re.sub(pat, r'\1inter 1s fall 1 rise 2', s)

# Ensure whole-slot failures actively tear down pinned sessions so clients reconnect.
for name in ('foreign_a', 'foreign_b'):
    s = re.sub(
        rf'^(\s*server {name} .*?rise 2)(?!.*on-marked-down shutdown-sessions)(\s*)$',
        r'\1 on-marked-down shutdown-sessions\2',
        s,
        flags=re.M,
    )

p.write_text(s)
PY

if ! haproxy -c -f "$CFG" >/dev/null; then
  cp -a "$backup" "$CFG"
  echo '[x] HAProxy validation failed; backup restored' >&2
  exit 2
fi

systemctl reload haproxy

echo '[+] Fast failover enabled.'
echo '[+] Health interval: 1s, fall=1, rise=2.'
echo '[+] Failed Foreign slot sessions are closed so clients can reconnect to the surviving slot.'
