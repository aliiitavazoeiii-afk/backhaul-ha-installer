#!/usr/bin/env bash
set -Eeuo pipefail

BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/agent/dual-foreign-active-active/dual-foreign-active-active/user-sync"
CFGDIR="/etc/dual-user-sync"
LIBDIR="/usr/local/lib/dual-user-sync"
CFG="$CFGDIR/config.json"
SYNC="$LIBDIR/dual_user_sync.py"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 curl ca-certificates >/dev/null
install -d -m 0700 "$CFGDIR"
install -d -m 0755 "$LIBDIR"

curl -fsSL "$BASE/dual_user_sync.py" -o "$SYNC"
chmod 0755 "$SYNC"
python3 -m py_compile "$SYNC"

echo
echo 'Dual-Foreign 3x-ui user sync setup'
echo 'Foreign A is PRIMARY / source of truth.'
echo 'Enter the full panel base URL, including any web base path.'
echo 'Example: http://193.57.9.144:2053/ or https://host:port/secretpath/'
echo

read -r -p 'Foreign A panel URL: ' A_URL
read -r -p 'Foreign A username: ' A_USER
read -r -s -p 'Foreign A password: ' A_PASS; echo
read -r -p 'Foreign B panel URL: ' B_URL
read -r -p 'Foreign B username: ' B_USER
read -r -s -p 'Foreign B password: ' B_PASS; echo

[[ -n "$A_URL" && -n "$A_USER" && -n "$A_PASS" && -n "$B_URL" && -n "$B_USER" && -n "$B_PASS" ]] || {
  echo '[x] URL/username/password fields cannot be empty' >&2; exit 2;
}

A_VERIFY=true
B_VERIFY=true
if [[ "$A_URL" == https://* ]]; then
  read -r -p 'Verify Foreign A TLS certificate? [Y/n]: ' x
  [[ "${x:-Y}" =~ ^[Yy]$ ]] || A_VERIFY=false
fi
if [[ "$B_URL" == https://* ]]; then
  read -r -p 'Verify Foreign B TLS certificate? [Y/n]: ' x
  [[ "${x:-Y}" =~ ^[Yy]$ ]] || B_VERIFY=false
fi

A_URL="$A_URL" A_USER="$A_USER" A_PASS="$A_PASS" A_VERIFY="$A_VERIFY" \
B_URL="$B_URL" B_USER="$B_USER" B_PASS="$B_PASS" B_VERIFY="$B_VERIFY" \
CFG="$CFG" python3 - <<'PY'
import json, os
cfg = {
  "primary": {
    "url": os.environ["A_URL"],
    "username": os.environ["A_USER"],
    "password": os.environ["A_PASS"],
    "verify_tls": os.environ["A_VERIFY"].lower() == "true",
    "target_listen": "127.0.0.1",
    "target_port": 443,
    "inbound_id": None,
    "timeout": 10
  },
  "secondary": {
    "url": os.environ["B_URL"],
    "username": os.environ["B_USER"],
    "password": os.environ["B_PASS"],
    "verify_tls": os.environ["B_VERIFY"].lower() == "true",
    "target_listen": "127.0.0.1",
    "target_port": 443,
    "inbound_id": None,
    "timeout": 10
  },
  "delete_mirroring": False
}
with open(os.environ["CFG"], "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(os.environ["CFG"], 0o600)
PY
unset A_PASS B_PASS

cat > /usr/local/bin/dual-usersync <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SYNC=/usr/local/lib/dual-user-sync/dual_user_sync.py
case "${1:-sync}" in
  sync) exec python3 "$SYNC" ;;
  check) exec python3 "$SYNC" --check ;;
  enable-delete) exec python3 "$SYNC" --enable-delete ;;
  disable-delete) exec python3 "$SYNC" --disable-delete ;;
  status)
    systemctl status dual-user-sync.timer dual-user-sync.service --no-pager || true
    ;;
  logs)
    journalctl -u dual-user-sync.service -n "${2:-60}" --no-pager
    ;;
  *) echo 'Usage: dual-usersync [sync|check|enable-delete|disable-delete|status|logs]' >&2; exit 2 ;;
esac
EOF
chmod 0755 /usr/local/bin/dual-usersync

cat > /etc/systemd/system/dual-user-sync.service <<'EOF'
[Unit]
Description=Dual-Foreign 3x-ui user mirror A -> B
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dual-usersync sync
User=root
Nice=10
EOF

cat > /etc/systemd/system/dual-user-sync.timer <<'EOF'
[Unit]
Description=Run Dual-Foreign 3x-ui user sync every 30 seconds

[Timer]
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true
Unit=dual-user-sync.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

echo
echo '[i] Checking both panel APIs and inbound discovery (no changes)...'
if ! dual-usersync check; then
  echo '[x] Validation failed. Timer was NOT enabled.' >&2
  echo '[i] Fix the panel URL/credentials in /etc/dual-user-sync/config.json and run: dual-usersync check' >&2
  exit 3
fi

echo
echo '[i] Running first safe synchronization (add/update only; no deletions)...'
dual-usersync sync

systemctl enable --now dual-user-sync.timer >/dev/null

echo
echo '[+] User sync installed and timer enabled.'
echo '[+] Source of truth: Foreign A'
echo '[+] Interval: 30 seconds'
echo '[+] Delete mirroring: OFF (safe mode)'
echo '[+] Check: dual-usersync check'
echo '[+] Run now: dual-usersync sync'
echo '[+] Logs: dual-usersync logs'
echo '[+] After delete testing: dual-usersync enable-delete'
