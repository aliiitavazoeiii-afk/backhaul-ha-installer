#!/usr/bin/env bash
set -Eeuo pipefail

ENGINE_REF='94aa555185c4c7e3b59ab9aae61ea5fd66086ed3'
BASE="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${ENGINE_REF}/dual-wss-stealth/user-sync"
CFGDIR=/etc/dual-user-sync
LIBDIR=/usr/local/lib/dual-user-sync
CFG="$CFGDIR/config.json"
SYNC="$LIBDIR/dual_user_sync.py"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[x] Run as root' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 curl ca-certificates >/dev/null
install -d -m 0700 "$CFGDIR"
install -d -m 0755 "$LIBDIR"

curl -fL --retry 4 --retry-delay 2 --retry-all-errors "$BASE/dual_user_sync.py" -o "$SYNC"
chmod 0755 "$SYNC"
python3 -m py_compile "$SYNC"
echo -n '[i] Installed user-sync version: '
python3 "$SYNC" --version

echo
echo 'Dual WSS Stealth - 3x-ui user mirror'
echo 'PRIMARY/source: Foreign A = 193.57.9.55'
echo 'SECONDARY/mirror: Foreign B = 193.57.9.184'
echo 'Use the exact full X-UI panel URLs, including any secret web base path.'
echo 'Credentials are entered locally here and are not printed.'
echo

read -r -p 'Foreign A (.55) full panel URL: ' A_URL
read -r -p 'Foreign A username: ' A_USER
read -r -s -p 'Foreign A password: ' A_PASS; echo
read -r -p 'Foreign B (.184) full panel URL: ' B_URL
read -r -p 'Foreign B username: ' B_USER
read -r -s -p 'Foreign B password: ' B_PASS; echo

[[ -n "$A_URL" && -n "$A_USER" && -n "$A_PASS" && -n "$B_URL" && -n "$B_USER" && -n "$B_PASS" ]] || {
  echo '[x] URL/username/password fields cannot be empty' >&2
  exit 2
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
  "delete_mirroring": False,
  "delete_guard": {
    "allow_empty_primary": False,
    "max_delete_count": 25,
    "max_delete_fraction": 0.50
  }
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
case "${1:-check}" in
  check) exec python3 "$SYNC" --check ;;
  sync) exec python3 "$SYNC" ;;
  activate)
    python3 "$SYNC"
    systemctl enable --now dual-user-sync.timer >/dev/null
    echo '[+] User sync timer enabled: every 30 seconds'
    ;;
  pause) systemctl disable --now dual-user-sync.timer >/dev/null 2>&1 || true; echo '[+] User sync timer disabled' ;;
  enable-delete) exec python3 "$SYNC" --enable-delete ;;
  disable-delete) exec python3 "$SYNC" --disable-delete ;;
  status) systemctl status dual-user-sync.timer dual-user-sync.service --no-pager || true ;;
  logs) journalctl -u dual-user-sync.service -n "${2:-80}" --no-pager ;;
  version) exec python3 "$SYNC" --version ;;
  *) echo 'Usage: dual-usersync [check|sync|activate|pause|enable-delete|disable-delete|status|logs|version]' >&2; exit 2 ;;
esac
EOF
chmod 0755 /usr/local/bin/dual-usersync

cat > /etc/systemd/system/dual-user-sync.service <<'EOF'
[Unit]
Description=Dual WSS Stealth 3x-ui mirror A -> B
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dual-usersync sync
User=root
UMask=0077
Nice=10
EOF

cat > /etc/systemd/system/dual-user-sync.timer <<'EOF'
[Unit]
Description=Run Dual WSS Stealth user sync every 30 seconds

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
systemctl disable --now dual-user-sync.timer >/dev/null 2>&1 || true

echo
echo '[i] Read-only validation follows. No X-UI user will be changed by this step.'
if ! dual-usersync check; then
  echo '[x] Validation failed. Timer remains OFF.' >&2
  exit 3
fi

echo
echo '[+] User-sync installed in STAGED mode.'
echo '[+] Primary: 193.57.9.55'
echo '[+] Secondary: 193.57.9.184'
echo '[+] Delete mirroring: OFF'
echo '[+] Timer: OFF until dual-usersync activate'
echo '[+] Review the Plan above before activation.'
