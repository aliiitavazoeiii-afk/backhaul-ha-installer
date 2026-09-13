#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/xhttp-dual"
CONFIG_DIR="/etc/xhttp-dual"
STATE_DIR="/var/lib/xhttp-dual"
CONTROLLER_SERVICE="xhttp-dual-controller.service"

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
XHTTP DUAL - REPLACE FOREIGN NODE (ONLINE-SAFE)
============================================================
Copy the EXACT values from the NEW Foreign server:
  cat /root/xhttp-reality-client.env

Fresh Foreign installs may use a unique same-server decoy SNI. Never guess
or reuse www.cloudflare.com/noded.cloud unless the NEW Foreign env literally
contains that value.

During the selected-node restart this helper pauses only the health controller.
It does NOT deliberately restart x-ui and does NOT force xhttp-dual sync.
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
prompt NEW_SNI "New Foreign #${NUM} REALITY SNI (EXACT value from client env)"
prompt NEW_PATH "New Foreign #${NUM} XHTTP Path"

[[ -n "$NEW_IP" && -n "$NEW_UUID" && -n "$NEW_PUB" && -n "$NEW_SID" && -n "$NEW_SNI" && -n "$NEW_PATH" ]] || { echo "All values are required."; exit 1; }
[[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1 && NEW_PORT <= 65535 )) || { echo "Invalid port"; exit 1; }
[[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid local SOCKS port in config"; exit 1; }

echo
echo "New node values to be tested:"
echo "  IP/port : ${NEW_IP}:${NEW_PORT}"
echo "  SNI     : ${NEW_SNI}"
echo "  XHTTP   : ${NEW_PATH}"

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

CONTROLLER_WAS_ACTIVE=0
if systemctl is-active --quiet "$CONTROLLER_SERVICE" 2>/dev/null; then
  CONTROLLER_WAS_ACTIVE=1
fi

rollback() {
  echo "Replacement failed. Rolling back ${NODE^^}..."
  cp -a "$BACKUP_DIR/${NODE}.json" "$NODE_JSON" || true
  cp -a "$BACKUP_DIR/config.json" "$CONFIG_DIR/config.json" || true
  if [[ -f "$BACKUP_DIR/$(basename "$ENV_FILE")" ]]; then
    cp -a "$BACKUP_DIR/$(basename "$ENV_FILE")" "$ENV_FILE" || true
  fi
  if [[ -f "$BACKUP_DIR/state.json" ]]; then
    cp -a "$BACKUP_DIR/state.json" "$STATE_DIR/state.json" || true
  fi
  systemctl restart "$SERVICE" || true
  if (( CONTROLLER_WAS_ACTIVE == 1 )); then
    systemctl start "$CONTROLLER_SERVICE" 2>/dev/null || true
  fi
  echo "Rollback complete. Backup: $BACKUP_DIR"
}
trap rollback ERR

echo "Pausing only the failover controller during planned ${NODE^^} replacement..."
if (( CONTROLLER_WAS_ACTIVE == 1 )); then
  systemctl stop "$CONTROLLER_SERVICE"
fi

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
jq --arg n "$NODE" --arg ip "$NEW_IP" --argjson port "$NEW_PORT" '.nodes[$n].foreign_ip=$ip | .nodes[$n].foreign_port=$port' "$CONFIG_DIR/config.json" >"$TMP_CFG"
install -m 0600 "$TMP_CFG" "$CONFIG_DIR/config.json"

systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE"
ss -lntH "( sport = :${SOCKS_PORT} )" | grep -q .

echo "Testing new ${NODE^^} end-to-end through its local SOCKS..."
HEALTH_OK=0
HEALTH_DETAIL=""
for URL in \
  "https://cp.cloudflare.com/generate_204" \
  "https://connectivitycheck.gstatic.com/generate_204"; do
  OUT="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 --connect-timeout 7 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" "$URL" 2>/dev/null || true)"
  CODE="${OUT%% *}"
  TOTAL="${OUT#* }"
  HEALTH_DETAIL="${URL} code=${CODE:-'-'} total=${TOTAL:-'-'}"
  if [[ "$CODE" == "200" || "$CODE" == "204" ]]; then
    HEALTH_OK=1
    echo "Health OK: $HEALTH_DETAIL"
    break
  fi
  echo "Health target failed: $HEALTH_DETAIL"
done
(( HEALTH_OK == 1 )) || { echo "New ${NODE^^} failed all end-to-end health targets."; false; }

EGRESS="unknown"
for URL in "https://api.ipify.org" "https://icanhazip.com"; do
  IP="$(curl -fsS --max-time 10 --connect-timeout 4 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" "$URL" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$IP" ]]; then EGRESS="$IP"; break; fi
done
echo "${NODE^^} egress: ${EGRESS}"

# The new path has just passed an end-to-end probe. Keep it available in state
# before resuming v4 so a planned replacement of a healthy node does not look
# like an outage and trigger an unnecessary x-ui routing rewrite.
if [[ -f "$STATE_DIR/state.json" ]]; then
  jq --arg n "$NODE" --arg detail "planned replacement verified: $HEALTH_DETAIL" '
    .nodes[$n].healthy=true |
    .nodes[$n].failures=0 |
    .nodes[$n].slow_failures=0 |
    .nodes[$n].successes=1 |
    .nodes[$n].drained=false |
    .nodes[$n].last_reason="ok" |
    .nodes[$n].last_detail=$detail
  ' "$STATE_DIR/state.json" >"$TMP/state.json"
  install -m 0600 "$TMP/state.json" "$STATE_DIR/state.json"
fi

if (( CONTROLLER_WAS_ACTIVE == 1 )); then
  systemctl start "$CONTROLLER_SERVICE"
  sleep 2
fi

# Do NOT run `xhttp-dual sync` here: sync is forceful and can restart x-ui.
# A normal controller resume will preserve sticky mappings unless a real health
# transition requires failover/failback.
if command -v xhttp-dual >/dev/null 2>&1; then
  xhttp-dual status || true
  if xhttp-dual netcheck >/dev/null 2>&1; then
    echo
    xhttp-dual netcheck || true
  fi
fi

trap - ERR

echo
echo "============================================================"
echo "${NODE^^} REPLACED SUCCESSFULLY"
echo "Old foreign : ${OLD_IP}"
echo "New foreign : ${NEW_IP}:${NEW_PORT}"
echo "SNI         : ${NEW_SNI}"
echo "Egress      : ${EGRESS}"
echo "x-ui        : not deliberately restarted by replacement"
echo "Backup      : ${BACKUP_DIR}"
echo "============================================================"
