#!/usr/bin/env bash
set -Eeuo pipefail

CODE_PIN='dd43ce878ea2fccd743ba764d76e709007fc102a'
AEGIS_PIN='ef0e8a44065ca537c976858c9f9ae8f7a503313c'
BACKUP_PIN='2be6343fb6af4e99d5c019eaf698e06047388b73'
REPO='aliiitavazoeiii-afk/backhaul-ha-installer'
BASE="https://raw.githubusercontent.com/${REPO}/${CODE_PIN}"
APP_DIR='/opt/aegis-dashboard'
BACKUP_ROOT='/root/aegis-dashboard-backups'
SERVICE='/etc/systemd/system/aegis-dashboard.service'

log(){ printf '[+] %s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run as root.'
command -v systemctl >/dev/null || die 'systemd is required.'

if ! command -v apt-get >/dev/null; then
  die 'This production installer currently supports Debian/Ubuntu only.'
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 curl ca-certificates openssh-client sqlite3 >/dev/null

if [[ -d "$APP_DIR" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$BACKUP_ROOT/$stamp"
  cp -a "$APP_DIR" "$BACKUP_ROOT/$stamp/app"
  log "Previous dashboard files backed up to $BACKUP_ROOT/$stamp"
fi

install -d -m 0755 "$APP_DIR/remote" "$APP_DIR/vendor"
fetch(){
  local url="$1" dst="$2"
  curl -fL --retry 3 --connect-timeout 10 "$url" -o "$dst"
}

fetch "$BASE/aegis-dashboard/app.py" "$APP_DIR/app.py"
fetch "$BASE/aegis-dashboard/provision.py" "$APP_DIR/provision.py"
fetch "$BASE/aegis-dashboard/ui.html" "$APP_DIR/ui.html"
fetch "$BASE/aegis-dashboard/remote/install-3xui-2.9.4.sh" "$APP_DIR/remote/install-3xui-2.9.4.sh"
fetch "https://raw.githubusercontent.com/${REPO}/${AEGIS_PIN}/aegis-single/install.sh" "$APP_DIR/vendor/install-aegis-single.sh"
fetch "https://raw.githubusercontent.com/${REPO}/${BACKUP_PIN}/aegis-single/add-direct-backup.sh" "$APP_DIR/vendor/add-direct-backup.sh"

python3 -m py_compile "$APP_DIR/app.py" "$APP_DIR/provision.py"
bash -n "$APP_DIR/remote/install-3xui-2.9.4.sh"
bash -n "$APP_DIR/vendor/install-aegis-single.sh"
bash -n "$APP_DIR/vendor/add-direct-backup.sh"
chmod 0644 "$APP_DIR/app.py" "$APP_DIR/provision.py" "$APP_DIR/ui.html"
chmod 0755 "$APP_DIR/remote/install-3xui-2.9.4.sh" "$APP_DIR/vendor/install-aegis-single.sh" "$APP_DIR/vendor/add-direct-backup.sh"

cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Aegis Control Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/aegis-dashboard
ExecStart=/usr/bin/python3 /opt/aegis-dashboard/app.py
Restart=on-failure
RestartSec=2s
User=root
Group=root
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$SERVICE"
systemctl daemon-reload
systemctl enable --now aegis-dashboard >/dev/null
sleep 2
systemctl is-active --quiet aegis-dashboard || {
  journalctl -u aegis-dashboard -n 50 --no-pager || true
  die 'Dashboard service failed to start.'
}

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8787/api/status || true)"
[[ "$code" == '403' ]] || die "Dashboard loopback auth probe returned HTTP ${code:-none}, expected 403."

[[ -s /etc/aegis-dashboard/token ]] || die 'Dashboard token was not created.'
[[ -s /root/.ssh/id_ed25519.pub ]] || die 'Dashboard SSH public key was not created.'
TOKEN="$(cat /etc/aegis-dashboard/token)"
IRAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

log 'Aegis Control Dashboard installed successfully.'
printf '\nSSH tunnel from your computer:\n  ssh -L 8787:127.0.0.1:8787 root@%s\n' "${IRAN_IP:-IRAN_IP}"
printf '\nThen open locally:\n  http://127.0.0.1:8787/?token=%s\n' "$TOKEN"
printf '\nController SSH public key (authorize once on each Foreign):\n%s\n' "$(cat /root/.ssh/id_ed25519.pub)"
printf '\nInstalling the dashboard did NOT reconcile or restart the current VPN topology.\n'
