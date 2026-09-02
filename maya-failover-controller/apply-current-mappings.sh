#!/usr/bin/env bash
set -Eeuo pipefail

APP="maya-failover"
ETC="/etc/${APP}"
STATE="/var/lib/${APP}"
SERVICE="${APP}.service"
CFG="${ETC}/config.json"
STATE_JSON="${STATE}/state.json"
CTRL="/opt/${APP}/controller.py"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r "$CFG" ]] || { echo "Missing $CFG" >&2; exit 1; }
[[ -r "$ETC/secrets.env" ]] || { echo "Missing $ETC/secrets.env" >&2; exit 1; }
[[ -r "$ETC/vless.env" ]] || { echo "Missing $ETC/vless.env; current VLESS monitor is not installed." >&2; exit 1; }
[[ -x "$CTRL" ]] || { echo "Missing $CTRL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { apt-get update -y >/dev/null && apt-get install -y jq >/dev/null; }

mkdir -p "$STATE/backups"
chmod 0700 "$ETC" "$STATE" "$STATE/backups"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$STATE/backups/pre-mapping-${TS}.tar.gz"
TMP_CFG="$(mktemp)"
TMP_STATE="$(mktemp)"
trap 'rm -f "$TMP_CFG" "$TMP_STATE"' EXIT

tar -czf "$BACKUP" "$CFG" "$STATE_JSON" 2>/dev/null || tar -czf "$BACKUP" "$CFG"
chmod 0600 "$BACKUP"

echo "Backup: $BACKUP"

jq '
  .services.maya1.main_iran_ip = "185.215.230.204" |
  .services.maya1.spare_iran_ip = "5.10.248.50" |
  .services.maya1.spare_domain = "frp2.biya2film.top" |
  .services.maya3.main_iran_ip = "94.184.4.38" |
  .services.maya3.spare_iran_ip = "185.215.230.207" |
  .services.maya3.spare_domain = "frp3.biya2film.top"
' "$CFG" > "$TMP_CFG"

jq -e '
  .services.maya1.main_iran_ip == "185.215.230.204" and
  .services.maya1.spare_iran_ip == "5.10.248.50" and
  .services.maya1.spare_domain == "frp2.biya2film.top" and
  .services.maya3.main_iran_ip == "94.184.4.38" and
  .services.maya3.spare_iran_ip == "185.215.230.207" and
  .services.maya3.spare_domain == "frp3.biya2film.top"
' "$TMP_CFG" >/dev/null

OLD_OFFSET=0
if [[ -r "$STATE_JSON" ]]; then
  OLD_OFFSET="$(jq -r '.telegram_offset // 0' "$STATE_JSON" 2>/dev/null || echo 0)"
fi
cat >"$TMP_STATE" <<EOF
{
  "services": {},
  "telegram_offset": ${OLD_OFFSET}
}
EOF

WAS_ACTIVE=0
if systemctl is-active --quiet "$SERVICE"; then
  WAS_ACTIVE=1
  systemctl stop "$SERVICE"
fi

install -m 0600 "$TMP_CFG" "$CFG"
install -m 0600 "$TMP_STATE" "$STATE_JSON"

set +e
"$CTRL" --diagnose
DIAG_RC=$?
set -e

if [[ $DIAG_RC -ne 0 ]]; then
  echo "Diagnostics failed. Rolling back mapping update." >&2
  tar -xzf "$BACKUP" -C /
  systemctl daemon-reload
  if [[ $WAS_ACTIVE -eq 1 ]]; then
    systemctl start "$SERVICE" || true
  fi
  exit "$DIAG_RC"
fi

systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null
sleep 2
systemctl is-active --quiet "$SERVICE" || {
  journalctl -u "$SERVICE" -n 100 --no-pager
  echo "Service failed after mapping update; restoring backup." >&2
  systemctl stop "$SERVICE" 2>/dev/null || true
  tar -xzf "$BACKUP" -C /
  systemctl start "$SERVICE" 2>/dev/null || true
  exit 1
}

echo
echo "MAYA MAPPINGS UPDATED"
echo "MAYA1 MAIN   185.215.230.204"
echo "MAYA1 SPARE  5.10.248.50  frp2.biya2film.top"
echo "MAYA3 MAIN   94.184.4.38"
echo "MAYA3 SPARE  185.215.230.207  frp3.biya2film.top"
echo
echo "Current status:"
"$CTRL" --diagnose || true
