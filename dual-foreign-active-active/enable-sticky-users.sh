#!/usr/bin/env bash
set -Eeuo pipefail

CFG=/etc/haproxy/haproxy.cfg
BACKUP_DIR=/root/dual-backhaul-backups

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }
[[ -f "$CFG" ]] || { echo '[x] HAProxy config not found' >&2; exit 1; }

grep -q '^backend vpn_users$' "$CFG" || { echo '[x] vpn_users backend not found' >&2; exit 1; }
grep -q 'server foreign_a 127.0.0.1:15001' "$CFG" || { echo '[x] Foreign A slot not found' >&2; exit 1; }
grep -q 'server foreign_b 127.0.0.1:15002' "$CFG" || { echo '[x] Foreign B slot not found' >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
cp -a "$CFG" "$BACKUP_DIR/haproxy.pre-sticky.$(date +%Y%m%d-%H%M%S).cfg"

python3 - "$CFG" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old='''backend vpn_users
    mode tcp
    balance leastconn
    option httpchk GET /healthz
    http-check expect status 200
    server foreign_a 127.0.0.1:15001 check port 15011 inter 3s fall 2 rise 3
    server foreign_b 127.0.0.1:15002 check port 15012 inter 3s fall 2 rise 3
'''
new='''backend vpn_users
    mode tcp
    balance roundrobin
    stick-table type ip size 1m expire 24h
    stick on src
    option redispatch
    retries 2
    option httpchk GET /healthz
    http-check expect status 200
    server foreign_a 127.0.0.1:15001 check port 15011 inter 3s fall 2 rise 3 on-marked-down shutdown-sessions
    server foreign_b 127.0.0.1:15002 check port 15012 inter 3s fall 2 rise 3 on-marked-down shutdown-sessions
'''
if new in s:
    print('[i] Sticky Active/Active already enabled')
elif old in s:
    s=s.replace(old,new,1)
    p.write_text(s)
    print('[+] Replaced leastconn with roundrobin + source stickiness')
else:
    raise SystemExit('[x] Expected vpn_users block was not found; no changes made')
PY

if ! haproxy -c -f "$CFG"; then
  last="$(ls -1t "$BACKUP_DIR"/haproxy.pre-sticky.*.cfg | head -n1)"
  cp -a "$last" "$CFG"
  echo '[x] HAProxy validation failed; backup restored' >&2
  exit 2
fi

systemctl reload haproxy

echo '[+] Sticky Active/Active enabled.'
echo '[+] New source IPs are assigned A/B by round-robin.'
echo '[+] Existing source IPs stay on their assigned Foreign for 24h of stick-table activity.'
echo '[+] If a Foreign slot goes DOWN, HAProxy removes it and reconnects are sent to the surviving slot.'
