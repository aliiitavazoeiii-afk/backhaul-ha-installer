#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -x "$INSTALL_DIR/xray" ]] || { echo "Dual XHTTP is not installed: $INSTALL_DIR/xray missing"; exit 1; }
[[ -f "$CONFIG_DIR/config.json" ]] || { echo "Missing $CONFIG_DIR/config.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

prompt() {
  local target="$1" text="$2" def="${3:-}" val=""
  read -r -p "$text${def:+ [$def]}: " val
  printf -v "$target" '%s' "${val:-$def}"
}

cat <<'EOF'
============================================================
XHTTP DUAL - REPLACE FOREIGN NODE
============================================================
1) Replace Foreign #1 (F1)
2) Replace Foreign #2 (F2)
0) Exit
EOF
read -r -p "Select: " CHOICE
case "$CHOICE" in
  1) NODE="f1"; NUM="1" ;;
  2) NODE="f2"; NUM="2" ;;
  0) exit 0 ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

OLD_IP="$(jq -r --arg n "$NODE" '.nodes[$n].foreign_ip // "-"' "$CONFIG_DIR/config.json")"
SOCKS_PORT="$(jq -r --arg n "$NODE" '.nodes[$n].socks_port' "$CONFIG_DIR/config.json")"
SERVICE="xhttp-dual-${NODE}.service"
NODE_JSON="$CONFIG_DIR/${NODE}.json"
ENV_FILE="$CONFIG_DIR/foreign${NUM}.env"

printf '\nCurrent %s: %s  (local SOCKS 127.0.0.1:%s)\n\n' "${NODE^^}" "$OLD_IP" "$SOCKS_PORT"

prompt NEW_IP "New Foreign #${NUM} IP/domain"
prompt NEW_PORT "New Foreign #${NUM} port" "443"
prompt NEW_UUID "New Foreign #${NUM} VLESS ID"
prompt NEW_PUB "New Foreign #${NUM} REALITY Password/PublicKey"
prompt NEW_SID "New Foreign #${NUM} Short ID"
prompt NEW_SNI "New Foreign #${NUM} REALITY SNI" "www.cloudflare.com"
prompt NEW_PATH "New Foreign #${NUM} XHTTP Path"

[[ -n "$NEW_IP" && -n "$NEW_UUID" && -n "$NEW_PUB" && -n "$NEW_SID" && -n "$NEW_SNI" && -n "$NEW_PATH" ]] || { echo "All values are required."; exit 1; }
[[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1 && NEW_PORT <= 65535 )) || { echo "Invalid port"; exit 1; }
[[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid local SOCKS port in config"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$STATE_DIR/replacement-backups/$STAMP-$NODE"
mkdir -p "$BACKUP_DIR"
chmod 700 "$STATE_DIR" "$STATE_DIR/replacement-backups" "$BACKUP_DIR" 2>/dev/null || true

cp -a "$NODE_JSON" "$BACKUP_DIR/${NODE}.json"
cp -a "$CONFIG_DIR/config.json" "$BACKUP_DIR/config.json"
[[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "$BACKUP_DIR/$(basename "$ENV_FILE")"
[[ -f "$STATE_DIR/state.json" ]] && cp -a "$STATE_DIR/state.json" "$BACKUP_DIR/state.json"

cat >"$TMP/${NODE}.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "local-socks-${NODE}",
    "listen": "127.0.0.1",
    "port": ${SOCKS_PORT},
    "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [{
    "tag": "xhttp-${NODE}",
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${NEW_IP}", "port": ${NEW_PORT}, "users": [{"id": "${NEW_UUID}", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "xhttpSettings": {"mode": "auto", "path": "${NEW_PATH}"},
      "realitySettings": {"serverName": "${NEW_SNI}", "fingerprint": "chrome", "publicKey": "${NEW_PUB}", "shortId": "${NEW_SID}"}
    },
    "mux": {"enabled": true, "concurrency": -1, "xudpConcurrency": 16, "xudpProxyUDP443": "allow"}
  }]
}
EOF

jq empty "$TMP/${NODE}.json"
"$INSTALL_DIR/xray" run -test -c "$TMP/${NODE}.json" >/dev/null

echo
read -r -p "Replace ${NODE^^} ${OLD_IP} -> ${NEW_IP}? Type YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled."; exit 0; }

rollback() {
  echo "Replacement failed. Rolling back ${NODE^^}..."
  cp -a "$BACKUP_DIR/${NODE}.json" "$NODE_JSON"
  cp -a "$BACKUP_DIR/config.json" "$CONFIG_DIR/config.json"
  if [[ -f "$BACKUP_DIR/$(basename "$ENV_FILE")" ]]; then
    cp -a "$BACKUP_DIR/$(basename "$ENV_FILE")" "$ENV_FILE"
  fi
  if [[ -f "$BACKUP_DIR/state.json" ]]; then
    cp -a "$BACKUP_DIR/state.json" "$STATE_DIR/state.json"
  fi
  systemctl restart "$SERVICE" || true
  systemctl restart xhttp-dual-controller.service 2>/dev/null || true
  echo "Rollback complete. Backup: $BACKUP_DIR"
}
trap rollback ERR

install -m 0600 "$TMP/${NODE}.json" "$NODE_JSON"

cat >"$ENV_FILE" <<EOF
FOREIGN_IP='${NEW_IP}'
PORT='${NEW_PORT}'
VLESS_ID='${NEW_UUID}'
REALITY_PASSWORD='${NEW_PUB}'
REALITY_SHORT_ID='${NEW_SID}'
SNI='${NEW_SNI}'
XHTTP_PATH='${NEW_PATH}'
SOCKS_PORT='${SOCKS_PORT}'
EOF
chmod 600 "$ENV_FILE"

TMP_CFG="$TMP/config.json"
jq --arg n "$NODE" --arg ip "$NEW_IP" '.nodes[$n].foreign_ip=$ip' "$CONFIG_DIR/config.json" >"$TMP_CFG"
install -m 0600 "$TMP_CFG" "$CONFIG_DIR/config.json"

if [[ -f "$STATE_DIR/state.json" ]]; then
  jq --arg n "$NODE" '.nodes[$n].healthy=null | .nodes[$n].failures=0 | .nodes[$n].successes=0 | .nodes[$n].drained=false | .nodes[$n].last_detail="replaced; awaiting health check"' "$STATE_DIR/state.json" >"$TMP/state.json"
  install -m 0600 "$TMP/state.json" "$STATE_DIR/state.json"
fi

systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"
ss -lntH "( sport = :${SOCKS_PORT} )" | grep -q .

echo "Testing new ${NODE^^} end-to-end..."
EGRESS="$(curl -fsS --max-time 25 --connect-timeout 8 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://icanhazip.com | tr -d '[:space:]')"
[[ -n "$EGRESS" ]]
echo "${NODE^^} egress: $EGRESS"

systemctl restart xhttp-dual-controller.service
sleep 2
if command -v xhttp-dual >/dev/null 2>&1; then
  xhttp-dual sync || true
  xhttp-dual status || true
fi

trap - ERR

echo
echo "============================================================"
echo "${NODE^^} REPLACED SUCCESSFULLY"
echo "Old foreign : ${OLD_IP}"
echo "New foreign : ${NEW_IP}:${NEW_PORT}"
echo "Egress      : ${EGRESS}"
echo "Backup      : ${BACKUP_DIR}"
echo "============================================================"
