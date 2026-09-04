#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
BASE_URL="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/maya-watchdog/maya-watchdog"

prompt(){ local n="$1" t="$2" d="${3:-}" v=""; read -r -p "$t${d:+ [$d]}: " v; printf -v "$n" '%s' "${v:-$d}"; }
prompt_secret(){ local n="$1" t="$2" v=""; read -r -s -p "$t: " v; echo; printf -v "$n" '%s' "$v"; }

echo "MAYA WATCHDOG INSTALL"
prompt IRAN_HOST "Iran server IP/host"
prompt IRAN_USER "Iran SSH user" "root"
prompt IRAN_PORT "Iran SSH port" "22"
prompt IRAN_KEY "Iran SSH private key path" "/root/.ssh/id_ed25519"
prompt MAYA_HOST "secure-gorilla IP/host"
prompt MAYA_USER "Maya SSH user" "root"
prompt MAYA_PORT "Maya SSH port" "22"
prompt MAYA_KEY "Maya SSH private key path" "/root/.ssh/id_ed25519"
prompt F1_IP "XHTTP Foreign F1 IP" "82.152.141.57"
prompt F2_IP "XHTTP Foreign F2 IP" "82.152.141.58"
prompt MAYA_DOMAIN "Maya1 domain" "maya1.biya2film.top"
prompt INTERVAL "Check interval seconds" "30"
prompt TG_ENABLED "Enable Telegram alerts? y/N" "N"
TG_TOKEN=""; TG_CHAT=""
if [[ "$TG_ENABLED" =~ ^[Yy]$ ]]; then
  prompt_secret TG_TOKEN "Telegram bot token"
  prompt TG_CHAT "Telegram chat id"
fi

apt-get update
apt-get install -y python3 curl openssh-client ca-certificates dnsutils
mkdir -p /opt/maya-watchdog /etc/maya-watchdog /var/lib/maya-watchdog
chmod 700 /etc/maya-watchdog /var/lib/maya-watchdog
curl -fsSL "$BASE_URL/watchdog.py" -o /opt/maya-watchdog/watchdog.py
chmod 0755 /opt/maya-watchdog/watchdog.py
python3 -m py_compile /opt/maya-watchdog/watchdog.py

export IRAN_HOST IRAN_USER IRAN_PORT IRAN_KEY MAYA_HOST MAYA_USER MAYA_PORT MAYA_KEY F1_IP F2_IP MAYA_DOMAIN INTERVAL TG_TOKEN TG_CHAT
python3 - <<'PY'
import json,os
cfg={
  'interval': int(os.environ['INTERVAL']),
  'failure_threshold': 3,
  'recovery_threshold': 2,
  'iran_ssh': {'host':os.environ['IRAN_HOST'],'user':os.environ['IRAN_USER'],'port':int(os.environ['IRAN_PORT']),'key':os.environ['IRAN_KEY']},
  'maya_ssh': {'host':os.environ['MAYA_HOST'],'user':os.environ['MAYA_USER'],'port':int(os.environ['MAYA_PORT']),'key':os.environ['MAYA_KEY']},
  'foreign_nodes': {
    'f1': {'ip':os.environ['F1_IP'],'port':443},
    'f2': {'ip':os.environ['F2_IP'],'port':443},
  },
  'maya': {'domain':os.environ['MAYA_DOMAIN'],'public_port':443,'max_state_age':180},
  'telegram': {'bot_token':os.environ.get('TG_TOKEN',''),'chat_id':os.environ.get('TG_CHAT','')},
}
open('/etc/maya-watchdog/config.json','w').write(json.dumps(cfg,indent=2)+'\n')
os.chmod('/etc/maya-watchdog/config.json',0o600)
PY

cat >/usr/local/bin/maya-watchdog <<'EOF'
#!/bin/sh
exec /usr/bin/python3 /opt/maya-watchdog/watchdog.py "$@"
EOF
chmod 0755 /usr/local/bin/maya-watchdog

cat >/etc/systemd/system/maya-watchdog.service <<'EOF'
[Unit]
Description=Maya/XHTTP external watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/maya-watchdog/watchdog.py daemon
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now maya-watchdog.service
sleep 2

echo
echo "SSH CHECKS"
ssh -o BatchMode=yes -o ConnectTimeout=7 -p "$IRAN_PORT" ${IRAN_KEY:+-i "$IRAN_KEY"} "$IRAN_USER@$IRAN_HOST" 'echo IRAN_SSH_OK' || true
ssh -o BatchMode=yes -o ConnectTimeout=7 -p "$MAYA_PORT" ${MAYA_KEY:+-i "$MAYA_KEY"} "$MAYA_USER@$MAYA_HOST" 'echo MAYA_SSH_OK' || true

echo
echo "INSTALL COMPLETE"
echo "Run: maya-watchdog status"
echo "Logs: journalctl -u maya-watchdog -f"
