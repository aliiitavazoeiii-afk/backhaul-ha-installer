#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_DIR="/usr/local/lib/xhttp-reality"
CONFIG_DIR="/etc/xhttp-reality"
SERVER_JSON="$CONFIG_DIR/server.json"
CLIENT_ENV="/root/xhttp-reality-client.env"
SERVER_ENV="/root/xhttp-reality-server-secrets.env"
XRAY_SERVICE="xhttp-reality-server.service"
BACKUP_ROOT="/var/lib/xhttp-reality-backups"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -x "$XRAY_DIR/xray" ]] || { echo "Missing Xray binary: $XRAY_DIR/xray"; exit 1; }
[[ -d "$BACKUP_ROOT" ]] || { echo "No hardening backups found."; exit 1; }

LATEST="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*-hardening' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print; exit}')"
[[ -n "$LATEST" && -d "$LATEST" ]] || { echo "No hardening backup directory found."; exit 1; }

for f in server.json xhttp-reality-client.env xhttp-reality-server-secrets.env; do
  [[ -f "$LATEST/$f" ]] || { echo "Backup is incomplete: $LATEST/$f missing"; exit 1; }
done

"$XRAY_DIR/xray" run -test -c "$LATEST/server.json" >/dev/null

echo "About to restore Foreign REALITY from: $LATEST"
read -r -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled."; exit 0; }

STAMP="$(date +%Y%m%d-%H%M%S)"
SAFETY="$BACKUP_ROOT/$STAMP-before-rollback"
mkdir -p "$SAFETY"
chmod 700 "$SAFETY"
cp -a "$SERVER_JSON" "$SAFETY/server.json"
cp -a "$CLIENT_ENV" "$SAFETY/xhttp-reality-client.env"
cp -a "$SERVER_ENV" "$SAFETY/xhttp-reality-server-secrets.env"
if [[ -d /etc/systemd/system/${XRAY_SERVICE}.d ]]; then
  cp -a /etc/systemd/system/${XRAY_SERVICE}.d "$SAFETY/xray-dropins"
fi

rollback_failed_restore() {
  echo "Restore failed; restoring pre-rollback safety snapshot..."
  cp -a "$SAFETY/server.json" "$SERVER_JSON" || true
  cp -a "$SAFETY/xhttp-reality-client.env" "$CLIENT_ENV" || true
  cp -a "$SAFETY/xhttp-reality-server-secrets.env" "$SERVER_ENV" || true
  rm -rf /etc/systemd/system/${XRAY_SERVICE}.d
  if [[ -d "$SAFETY/xray-dropins" ]]; then
    cp -a "$SAFETY/xray-dropins" /etc/systemd/system/${XRAY_SERVICE}.d
  fi
  systemctl daemon-reload || true
  systemctl restart "$XRAY_SERVICE" || true
  echo "Safety snapshot: $SAFETY"
}
trap rollback_failed_restore ERR

install -m 0600 "$LATEST/server.json" "$SERVER_JSON"
install -m 0600 "$LATEST/xhttp-reality-client.env" "$CLIENT_ENV"
install -m 0600 "$LATEST/xhttp-reality-server-secrets.env" "$SERVER_ENV"
rm -rf /etc/systemd/system/${XRAY_SERVICE}.d
if [[ -d "$LATEST/xray-dropins" ]]; then
  cp -a "$LATEST/xray-dropins" /etc/systemd/system/${XRAY_SERVICE}.d
fi

systemctl daemon-reload
systemctl restart "$XRAY_SERVICE"
sleep 2
systemctl is-active --quiet "$XRAY_SERVICE"
"$XRAY_DIR/xray" run -test -c "$SERVER_JSON" >/dev/null
trap - ERR

echo
echo "FOREIGN REALITY ROLLBACK OK"
echo "Restored from : $LATEST"
echo "Safety copy   : $SAFETY"
echo "Client values : $CLIENT_ENV"
echo "Use the restored SNI from that file on Iran if needed."
