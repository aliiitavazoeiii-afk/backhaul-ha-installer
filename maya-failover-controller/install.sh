#!/usr/bin/env bash
set -Eeuo pipefail

APP="maya-failover"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
OPT="/opt/${APP}"
SERVICE="${APP}.service"
SOURCE_COMMIT="32c23d6cc3c76fbefa3f7b96db184e9946fe323c"
RAW="https://raw.githubusercontent.com/aliiitavazoeiii-afk/backhaul-ha-installer/${SOURCE_COMMIT}/maya-failover-controller/controller.py"
ZONE_NAME="biya2film.top"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 ca-certificates curl jq iputils-ping >/dev/null

mkdir -p "$ETC" "$STATE" "$OPT"
chmod 0700 "$ETC" "$STATE"

printf 'Cloudflare API Token (Zone:Read + DNS:Edit for biya2film.top): '
read -r -s CF_TOKEN
echo
[[ -n "$CF_TOKEN" ]] || { echo "Cloudflare token is required" >&2; exit 1; }

CF_AUTH=(-H "Authorization: Bearer ${CF_TOKEN}" -H 'Content-Type: application/json')
ZONE_JSON="$(curl -fsS "${CF_AUTH[@]}" "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}&status=active")"
ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$ZONE_JSON")"
[[ -n "$ZONE_ID" ]] || { echo "Could not resolve Cloudflare zone. Check token permissions." >&2; exit 1; }

declare -A RECORD_IDS
for name in maya1.biya2film.top maya3.biya2film.top; do
  rjson="$(curl -fsS "${CF_AUTH[@]}" "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${name}")"
  rid="$(jq -r '.result[0].id // empty' <<<"$rjson")"
  rip="$(jq -r '.result[0].content // empty' <<<"$rjson")"
  [[ -n "$rid" ]] || { echo "Missing Cloudflare A record: $name" >&2; exit 1; }
  case "$name:$rip" in
    maya1.biya2film.top:185.215.230.204|maya1.biya2film.top:5.10.248.50|maya3.biya2film.top:94.184.4.38|maya3.biya2film.top:185.215.230.207) ;;
    *) echo "Refusing install: $name currently points to unexpected IP $rip" >&2; exit 1 ;;
  esac
  RECORD_IDS["$name"]="$rid"
  echo "Cloudflare OK: $name -> $rip"
done

printf 'Telegram Bot Token: '
read -r -s TG_TOKEN
echo
[[ -n "$TG_TOKEN" ]] || { echo "Telegram bot token is required" >&2; exit 1; }

ME="$(curl -fsS "https://api.telegram.org/bot${TG_TOKEN}/getMe")"
[[ "$(jq -r '.ok' <<<"$ME")" == "true" ]] || { echo "Telegram token is invalid" >&2; exit 1; }
BOT_USER="$(jq -r '.result.username' <<<"$ME")"
echo "Telegram bot verified: @${BOT_USER}"

echo "Send /start to @${BOT_USER} now, then press ENTER here."
read -r _
UPDATES="$(curl -fsS "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?limit=20")"
TG_CHAT_ID="$(jq -r '[.result[] | select(.message.chat.id != null) | .message.chat.id] | last // empty' <<<"$UPDATES")"
if [[ -z "$TG_CHAT_ID" ]]; then
  read -r -p 'Telegram Chat ID (could not auto-detect): ' TG_CHAT_ID
fi
[[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]] || { echo "Invalid Telegram chat ID" >&2; exit 1; }

cat >"$ETC/secrets.env" <<EOF
CLOUDFLARE_API_TOKEN=${CF_TOKEN}
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_CHAT_ID=${TG_CHAT_ID}
EOF
chmod 0600 "$ETC/secrets.env"
unset CF_TOKEN TG_TOKEN

cat >"$ETC/config.json" <<EOF
{
  "cloudflare": {
    "zone": "biya2film.top",
    "zone_id": "${ZONE_ID}",
    "ttl": 60
  },
  "policy": {
    "interval_seconds": 30,
    "main_failures_before_failover": 3,
    "main_successes_before_recovery_notice": 10,
    "auto_failback": false
  },
  "services": {
    "maya1": {
      "domain": "maya1.biya2film.top",
      "record_id": "${RECORD_IDS[maya1.biya2film.top]}",
      "main_iran_ip": "185.215.230.204",
      "main_foreign_ip": "193.57.9.31",
      "spare_iran_ip": "5.10.248.50",
      "spare_foreign_ip": "193.57.9.181",
      "spare_domain": "zapasmaya3.biya2film.top",
      "spare_wss_port": 8443,
      "reality_sni": "swscan.apple.com"
    },
    "maya3": {
      "domain": "maya3.biya2film.top",
      "record_id": "${RECORD_IDS[maya3.biya2film.top]}",
      "main_iran_ip": "94.184.4.38",
      "main_foreign_ip": "193.57.9.167",
      "spare_iran_ip": "185.215.230.207",
      "spare_foreign_ip": "193.57.9.212",
      "spare_domain": "zapasmaya1.biya2film.top",
      "spare_wss_port": 8443,
      "reality_sni": "swscan.apple.com"
    }
  }
}
EOF
chmod 0600 "$ETC/config.json"

curl -fsSL --retry 4 "$RAW" -o "$OPT/controller.py"
python3 -m py_compile "$OPT/controller.py"
chmod 0755 "$OPT/controller.py"

cat >"/usr/local/bin/maya-failover" <<'EOF'
#!/usr/bin/env bash
set -e
case "${1:-status}" in
  status) systemctl status maya-failover --no-pager -l ;;
  logs) journalctl -u maya-failover -f ;;
  health|diagnose) /opt/maya-failover/controller.py --diagnose ;;
  restart) systemctl restart maya-failover ;;
  stop) systemctl stop maya-failover ;;
  start) systemctl start maya-failover ;;
  *) echo "Usage: maya-failover {status|logs|diagnose|restart|stop|start}"; exit 2 ;;
esac
EOF
chmod 0755 /usr/local/bin/maya-failover

cat >"/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=Maya1/Maya3 Cloudflare Failover Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${OPT}/controller.py
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=${STATE}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

set +e
"$OPT/controller.py" --diagnose
DIAG_RC=$?
set -e
if [[ $DIAG_RC -ne 0 ]]; then
  echo
  echo "DIAGNOSTICS NOT FULLY GREEN. Service was NOT started."
  echo "Run: maya-failover diagnose"
  exit "$DIAG_RC"
fi

systemctl enable --now "$SERVICE" >/dev/null
sleep 2
systemctl is-active --quiet "$SERVICE" || {
  journalctl -u "$SERVICE" -n 100 --no-pager
  exit 1
}

echo
echo "OK Maya Failover Controller is running on this management server."
echo "Commands:"
echo "  maya-failover status"
echo "  maya-failover diagnose"
echo "  maya-failover logs"
echo "Telegram: /status, /spare maya1, /main maya1, /spare maya3, /main maya3"
